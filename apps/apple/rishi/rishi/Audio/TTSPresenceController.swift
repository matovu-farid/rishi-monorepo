import Foundation
import RishiAudio
import SwiftUI

#if os(iOS) && canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class TTSPresenceController {

    private let state: TTSPlaybackState
    private let store: any TTSPresenceStore

    private var currentSessionID = UUID().uuidString
    private var currentBookID: String = ""
    private var currentBookTitle: String = ""
    private var currentBookAuthor: String?
    private var currentVoice = ""
    private var currentSpeed: Double = 1.0
    private var lastSnapshot: TTSPresenceSnapshot?
    private var observationTask: Task<Void, Never>?

#if os(iOS) && canImport(ActivityKit)
    private var activity: Activity<TTSPresenceAttributes>?
#endif

    init(state: TTSPlaybackState, store: any TTSPresenceStore) {
        self.state = state
        self.store = store
    }

    func beginSession(bookID: String, title: String, author: String?, voice: String, speed: Double) async {
        currentSessionID = UUID().uuidString
        currentBookID = bookID
        currentBookTitle = title
        currentBookAuthor = author
        currentVoice = voice
        currentSpeed = speed
        let initialSnapshot = makeSnapshot(forceStatus: .loading)
        lastSnapshot = initialSnapshot
        store.write(initialSnapshot)
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: TTSPresenceEnvironment.widgetKind)
#endif
#if os(iOS) && canImport(ActivityKit)
        await updateLiveActivity(with: initialSnapshot)
#endif
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.publishSnapshot()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func updateReadingMetadata(bookID: String, title: String, author: String?) async {
        currentBookID = bookID
        currentBookTitle = title
        currentBookAuthor = author
        await publishSnapshot()
    }

    func updatePlaybackSettings(voice: String, speed: Double) async {
        currentVoice = voice
        currentSpeed = speed
        await publishSnapshot()
    }

    func endSession() async {
        observationTask?.cancel()
        observationTask = nil
        let finalSnapshot = makeSnapshot(forceStatus: .stopped)
        store.write(finalSnapshot)
        lastSnapshot = finalSnapshot
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: TTSPresenceEnvironment.widgetKind)
#endif
#if os(iOS) && canImport(ActivityKit)
        if let activity {
            await activity.end(
                ActivityContent(state: TTSPresenceAttributes.ContentState(snapshot: finalSnapshot), staleDate: nil),
                dismissalPolicy: .default
            )
            self.activity = nil
        }
#endif
    }

    private func publishSnapshot() async {
        let snapshot = makeSnapshot(forceStatus: nil)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        store.write(snapshot)
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: TTSPresenceEnvironment.widgetKind)
#endif
#if os(iOS) && canImport(ActivityKit)
        await updateLiveActivity(with: snapshot)
#endif
    }

    private func makeSnapshot(forceStatus: TTSStatus?) -> TTSPresenceSnapshot {
        let status = forceStatus ?? state.status
        let currentPassageID = state.currentPassageId
        let currentPassageIndex = currentPassageID.flatMap(Int.init)
        return TTSPresenceSnapshot(
            sessionID: currentSessionID,
            bookID: currentBookID,
            bookTitle: currentBookTitle,
            bookAuthor: currentBookAuthor,
            status: status,
            currentPassageID: currentPassageID,
            currentPassageIndex: currentPassageIndex,
            voice: currentVoice,
            speed: currentSpeed,
            elapsed: state.elapsed
        )
    }

#if os(iOS) && canImport(ActivityKit)
    private func updateLiveActivity(with snapshot: TTSPresenceSnapshot) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(
            state: TTSPresenceAttributes.ContentState(snapshot: snapshot),
            staleDate: nil
        )

        if snapshot.isActive {
            if activity == nil {
                let attributes = TTSPresenceAttributes(sessionID: snapshot.sessionID)
                do {
                    activity = try Activity.request(
                        attributes: attributes,
                        content: content,
                        pushType: nil
                    )
                } catch {
                    activity = nil
                }
            } else if let activity {
                await activity.update(content)
            }
        } else if let activity {
            await activity.end(content, dismissalPolicy: .default)
            self.activity = nil
        }
    }
#endif
}
