import SwiftUI

/// Stable, non-observing shared-reading actions inserted into the reader's
/// native More menu. Live session state must stay out of this view: navigation
/// and playback sync update the runtime continuously, and rebuilding a native
/// Menu while it's presented can make the system dismiss it.
struct SharedReadingReaderMenuContent: View {
    let hasInvitation: Bool
    let onInvite: () -> Void
    let onManageReaders: () -> Void
    let onLeaveSharedReading: () -> Void

    var body: some View {
        Section("Shared reading") {
            if hasInvitation {
                Button("Invite readers…") { onInvite() }
            }
            Button("Participants…", action: onManageReaders)
            Button("Leave shared reading", role: .destructive) {
                onLeaveSharedReading()
            }
        }
    }
}

/// Live session details and controller actions live outside the system Menu so
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
