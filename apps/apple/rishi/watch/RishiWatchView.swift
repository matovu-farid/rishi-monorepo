#if os(watchOS)

import SwiftUI
import RishiWatchShared

struct RishiWatchView: View {
    @State private var model: RishiWatchViewModel

    init(model: RishiWatchViewModel) { _model = State(initialValue: model) }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let snapshot = model.snapshot {
                    Text(snapshot.title ?? "Rishi")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(snapshot.currentNarrationUnit ?? "No narration unit")
                        .font(.footnote)
                        .lineLimit(2)
                    if let chapterTitle = snapshot.chapterTitle {
                        Text(chapterTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ProgressView(value: snapshot.progress ?? 0)
                    if case .active = snapshot.availability {
                        HStack {
                            Button("Previous") { model.send(.previousUnit) }
                            Button(snapshot.isPlaying ? "Pause" : "Play") { model.send(.togglePlayback) }
                            Button("Next") { model.send(.nextUnit) }
                        }
                        .disabled(model.pendingRequest != nil)
                        Button("Stop", role: .destructive) { model.send(.stop) }
                            .disabled(model.pendingRequest != nil)
                        Picker("Rate", selection: Binding(
                            get: { snapshot.playbackRate ?? 1 },
                            set: { model.send(.setPlaybackRate($0)) }
                        )) {
                            ForEach(snapshot.supportedPlaybackRates, id: \.self) { rate in
                                Text(String(format: "%.2gx", rate)).tag(rate)
                            }
                        }
                        .disabled(model.pendingRequest != nil)
                    } else {
                        Text("Start narration on iPhone")
                            .font(.caption)
                    }
                } else {
                    Text("Open Rishi on iPhone")
                    Button("Refresh") { model.refresh() }
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage).font(.caption2)
                }
                if model.isRetryable {
                    Button("Retry") { model.retryPendingRequest() }
                }
            }
            .padding()
        }
        .task {
            model.start()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                model.tick()
            }
        }
    }
}

#endif
