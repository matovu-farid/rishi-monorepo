import SwiftUI

struct SharedReadingSessionView: View {
    let api: SharedReadingAPI
    let coordinator: SharedReadingSessionCoordinator
    let transport: SharedReadingSignalingClient
    let join: SharedReadingJoin
    let localParticipantUserId: String

    @Environment(\.dismiss) private var dismiss
    @State private var message = "Connecting to the reading room…"
    @State private var isConnected = false
    @State private var isBusy = false
    @State private var snapshot: SharedReadingSessionCoordinatorSnapshot?
    @State private var roomStatus: SharedReadingRoomStatus?
    @State private var peerMesh: SharedReadingPeerMesh?
    @State private var audioMixer = SharedReadingAudioMixer()
    @State private var remoteAudioUserIds = Set<String>()
    @State private var showControllerLeaveDialog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: join.admission.status == .active ? "person.3.fill" : "hourglass")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text(join.admission.status == .active ? "Reading session" : "Waiting room")
                    .font(.title2.bold())
                Text(currentStatus == .active
                     ? "The session is active. Your book is ready to read locally."
                     : "Your book is ready. The initial sharer has not started reading yet.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Label(message, systemImage: isConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(isConnected ? .green : .secondary)
                let participants = visibleParticipants
                if !participants.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Readers \(participants.count)/\(roomStatus?.maxParticipants ?? 5)")
                            .font(.headline)
                        ForEach(participants) { participant in
                            HStack {
                                Label(
                                    participant.isController ? "\(participant.displayName) · controller" : participant.displayName,
                                    systemImage: participant.isController ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                                )
                                .font(.subheadline)
                                Spacer()
                                if isLocalController && participant.userId != localParticipantUserId {
                                    Menu {
                                        Button("Make controller") { transferController(to: participant) }
                                        Button("Remove from session", role: .destructive) { remove(participant) }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .accessibilityLabel("Manage \(participant.displayName)")
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isLocalController && !removedParticipantIds.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Removed readers")
                            .font(.headline)
                        ForEach(removedParticipantIds.sorted(), id: \.self) { userId in
                            Button("Restore \(userId)") { restore(userId: userId) }
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let bookId = UUID(uuidString: join.response.book.bookId) {
                    NavigationLink {
                        ReaderDestinationView(
                            route: join.response.book.format == .pdf ? .pdf(bookId) : .epub(bookId),
                            hint: nil,
                            onRequestPaywall: { _ in },
                            sharedReadingCoordinator: coordinator,
                            sharedReadingJoin: join,
                            sharedReadingPeerMesh: peerMesh
                        )
                    } label: {
                        Label("Open book", systemImage: "book.pages")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if currentStatus == .waiting && isLocalController {
                    Button("Start reading") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                } else if currentStatus == .waiting {
                    Label("Waiting for the initial sharer to start", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                if isConnected {
                    if !remoteAudioUserIds.isEmpty {
                        Label("Audio connected", systemImage: "waveform")
                            .foregroundStyle(.secondary)
                    }
                }
                if isLocalController {
                    Button("Leave session", role: .destructive) { showControllerLeaveDialog = true }
                        .disabled(isBusy)
                } else {
                    Button("Leave session", role: .destructive) { leave() }
                        .disabled(isBusy)
                }
            }
            .padding(24)
            .navigationTitle("Shared reading")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await connect() }
        .task(id: peerMesh != nil) { await consumePeerStates() }
        .task(id: peerMesh != nil) { await consumeRemoteAudio() }
        .onDisappear {
            Task {
                await peerMesh?.close()
                await transport.disconnect()
            }
        }
        .confirmationDialog("Leave reading session", isPresented: $showControllerLeaveDialog) {
            Button("Leave and end for everyone", role: .destructive) { endSession() }
            Button("Leave and choose another controller") { leave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can end the room for everyone or leave it running with automatic controller transfer.")
        }
    }

    private var currentStatus: SharedReadingSessionStatus {
        snapshot?.status ?? join.admission.status
    }

    private var isLocalController: Bool {
        (snapshot?.currentParticipantUserId ?? roomStatus?.controllerUserId) == localParticipantUserId
    }

    private var visibleParticipants: [SharedReadingParticipant] {
        if let participants = snapshot?.participants, !participants.isEmpty {
            return participants
        }
        return roomStatus?.participants ?? []
    }

    private var removedParticipantIds: Set<String> {
        Set(roomStatus?.removedUserIds ?? [])
    }

    private func connect() async {
        do {
            let bearer = try await api.bearerToken()
            try await coordinator.connect(admission: join.admission, bearerToken: bearer)
            let status = try? await api.status(sessionId: join.response.sessionId)
            let mesh = SharedReadingPeerMesh(localParticipantUserId: localParticipantUserId, signaling: transport)
            let initialMicrophoneEnabled = SharedReadingMicrophonePolicyState()
                .microphoneEnabled(isTTSPlaying: false)
            await mesh.setMicrophoneEnabled(initialMicrophoneEnabled)
            if let status {
                do {
                    let turn = try await api.turnCredentials(sessionId: join.response.sessionId)
                    try await mesh.start(participants: status.participants, turnCredentials: turn)
                    await MainActor.run { roomStatus = status; peerMesh = mesh }
                } catch let error as SharedReadingError {
                    await MainActor.run {
                        roomStatus = status
                        peerMesh = mesh
                        message = "Connected, but voice is unavailable: \(error.message)"
                    }
                } catch {
                    await MainActor.run {
                        roomStatus = status
                        peerMesh = mesh
                        message = "Connected, but voice is unavailable right now."
                    }
                }
            } else {
                await MainActor.run { peerMesh = mesh }
            }
            await MainActor.run { isConnected = true; message = message.hasPrefix("Connected, but") ? message : "Connected" }
            for await snapshot in coordinator.stateUpdates {
                await MainActor.run {
                    self.snapshot = snapshot
                    switch snapshot.status {
                    case .active: message = "Reading session is active"
                    case .waiting: message = "Waiting for the initial sharer"
                    case .ended: message = "This reading session has ended"
                    }
                    isConnected = snapshot.status != .ended
                }
            }
        } catch let error as SharedReadingError {
            await MainActor.run { message = error.message }
        } catch {
            await MainActor.run { message = "Rishi could not connect to this reading session." }
        }
    }

    private func consumePeerStates() async {
        guard let mesh = peerMesh else { return }
        for await event in mesh.peerStates {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                audioMixer.consume(peerState: event)
                remoteAudioUserIds = audioMixer.snapshot().remoteAudioUserIds
                if event.state == .failed {
                    message = "Connected, but one participant's audio is unavailable."
                }
            }
        }
    }

    private func consumeRemoteAudio() async {
        guard let mesh = peerMesh else { return }
        for await event in mesh.remoteAudioEvents {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                audioMixer.consume(remoteAudio: event)
                remoteAudioUserIds = audioMixer.snapshot().remoteAudioUserIds
            }
        }
    }

    private func start() {
        isBusy = true
        Task {
            do {
                try await coordinator.start()
                await MainActor.run { isBusy = false; message = "Reading session is active" }
            } catch let error as SharedReadingError {
                await MainActor.run { isBusy = false; message = error.message }
            } catch {
                await MainActor.run { isBusy = false; message = "Only the current controller can start the session." }
            }
        }
    }

    private func leave() {
        isBusy = true
        Task {
            await coordinator.leave()
            await MainActor.run { dismiss() }
        }
    }

    private func endSession() {
        isBusy = true
        Task {
            do {
                try await coordinator.end()
                await MainActor.run { isBusy = false; dismiss() }
            } catch let error as SharedReadingError {
                await MainActor.run { isBusy = false; message = error.message }
            } catch {
                await MainActor.run { isBusy = false; message = "Rishi could not end the reading session." }
            }
        }
    }

    private func transferController(to participant: SharedReadingParticipant) {
        isBusy = true
        Task {
            do {
                _ = try await api.transferController(sessionId: join.response.sessionId, targetUserId: participant.userId)
                await refreshStatus(message: "Controller transferred to \(participant.displayName)")
            } catch let error as SharedReadingError {
                await MainActor.run { isBusy = false; message = error.message }
            } catch {
                await MainActor.run { isBusy = false; message = "Rishi could not transfer control." }
            }
        }
    }

    private func remove(_ participant: SharedReadingParticipant) {
        isBusy = true
        Task {
            do {
                _ = try await api.removeParticipant(sessionId: join.response.sessionId, participantUserId: participant.userId)
                await refreshStatus(message: "\(participant.displayName) was removed from the session")
            } catch let error as SharedReadingError {
                await MainActor.run { isBusy = false; message = error.message }
            } catch {
                await MainActor.run { isBusy = false; message = "Rishi could not remove that participant." }
            }
        }
    }

    private func restore(userId: String) {
        isBusy = true
        Task {
            do {
                _ = try await api.restoreParticipant(
                    sessionId: join.response.sessionId,
                    participantUserId: userId,
                    contentHash: join.response.book.contentHash
                )
                await refreshStatus(message: "Participant restored; they can rejoin when ready")
            } catch let error as SharedReadingError {
                await MainActor.run { isBusy = false; message = error.message }
            } catch {
                await MainActor.run { isBusy = false; message = "Rishi could not restore that participant." }
            }
        }
    }

    private func refreshStatus(message nextMessage: String) async {
        let updated = try? await api.status(sessionId: join.response.sessionId)
        await MainActor.run {
            if let updated { roomStatus = updated }
            isBusy = false
            message = nextMessage
        }
    }

}
