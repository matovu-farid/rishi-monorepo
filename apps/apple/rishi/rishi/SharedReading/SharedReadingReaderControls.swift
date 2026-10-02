import SwiftUI

/// Stable, non-observing shared-reading actions inserted into the reader's
/// More popover. Live session state must stay out of this view: navigation and
/// playback sync update the runtime continuously and should not rebuild the
/// presentation while it is open.
struct SharedReadingReaderMenuContent: View {
    @Environment(\.readerMoreMenuPresentation) private var menuPresentation

    let hasInvitation: Bool
    let onInvite: () -> Void
    let onManageReaders: () -> Void
    let onLeaveSharedReading: () -> Void

    var body: some View {
        Section("Shared reading") {
            if hasInvitation {
                Button("Invite readers…") { perform { onInvite() } }
            }
            Button("Participants…") { perform { onManageReaders() } }
            Button("Leave shared reading", role: .destructive) {
                perform { onLeaveSharedReading() }
            }
        }
    }

    private func perform(_ action: @escaping @MainActor () -> Void) {
        if let menuPresentation {
            menuPresentation.dismiss(then: action)
        } else {
            action()
        }
    }
}

/// Live session details and controller actions live outside the More popover so
/// roster/progress updates cannot invalidate its presentation.
struct SharedReadingReaderControlsSurface: View {
    @Bindable var runtime: SharedReadingSessionRuntime

    var body: some View {
        List {
            Section("Reading session") {
                Text(runtime.message)
            }
            Section("Readers") {
                ForEach(runtime.visibleParticipants) { participant in
                    Text(participant.isController ? "\(participant.displayName) · controller" : participant.displayName)
                    if runtime.isLocalController,
                       participant.userId != runtime.localParticipantUserID {
                        Button("Make \(participant.displayName) controller") {
                            Task { await runtime.transferController(to: participant) }
                        }
                        .disabled(!runtime.canUseSessionControls || runtime.isBusy)

                        Button("Remove \(participant.displayName)", role: .destructive) {
                            Task { await runtime.remove(participant) }
                        }
                        .disabled(!runtime.canUseSessionControls || runtime.isBusy)
                    }
                }
                if runtime.isLocalController {
                    ForEach(runtime.removedParticipantIDs.sorted(), id: \.self) { userID in
                        Button("Restore \(userID)") {
                            Task { await runtime.restore(userID: userID) }
                        }
                        .disabled(!runtime.canUseSessionControls || runtime.isBusy)
                    }
                }
            }
        }
    }
}
