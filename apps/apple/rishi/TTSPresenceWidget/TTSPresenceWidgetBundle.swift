import Foundation
@preconcurrency import ActivityKit
import SwiftUI
import WidgetKit

private enum TTSPresenceEnvironment {
    static let appGroupIdentifier = "group.org.fidexa.rishi"
    static let snapshotKey = "tts.presence.snapshot"
    static let widgetKind = "org.fidexa.rishi.tts.presence"
}

private enum TTSStatus: String, Codable {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case error
}

private struct TTSPresenceSnapshot: Codable, Hashable {
    let sessionID: String
    let bookID: String
    let bookTitle: String
    let bookAuthor: String?
    let status: TTSStatus
    let currentPassageID: String?
    let currentPassageIndex: Int?
    let voice: String
    let speed: Double
    let elapsed: TimeInterval
    let updatedAt: Date

    var isActive: Bool {
        status == .loading || status == .playing || status == .paused
    }

    var statusLabel: String {
        switch status {
        case .idle: return "Ready"
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }

    var subtitle: String {
        bookAuthor?.isEmpty == false ? bookAuthor! : "Unknown author"
    }

    var passageLabel: String? {
        currentPassageIndex.map { "Paragraph \($0 + 1)" }
    }
}

private final class UserDefaultsTTSPresenceStore {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(groupIdentifier: String = TTSPresenceEnvironment.appGroupIdentifier) {
        guard let defaults = UserDefaults(suiteName: groupIdentifier) else {
            preconditionFailure("Unable to open app group defaults: \(groupIdentifier)")
        }
        self.defaults = defaults
    }

    func read() -> TTSPresenceSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: TTSPresenceEnvironment.snapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(TTSPresenceSnapshot.self, from: data)
    }
}

@available(iOS 16.1, *)
private struct TTSPresenceAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var snapshot: TTSPresenceSnapshot
    }

    let sessionID: String
}

@main
struct TTSPresenceWidgetBundle: WidgetBundle {
    var body: some Widget {
        TTSPresenceWidget()
        if #available(iOS 16.1, *) {
            TTSPresenceLiveActivityWidget()
        }
    }
}

struct TTSPresenceWidget: Widget {
    private let store = UserDefaultsTTSPresenceStore()

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TTSPresenceEnvironment.widgetKind, provider: TTSPresenceWidgetProvider(store: store)) { entry in
            TTSPresenceWidgetView(entry: entry)
        }
        .configurationDisplayName("Read Aloud")
        .description("Shows the current read-aloud session and opens the reader.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct TTSPresenceWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: TTSPresenceSnapshot?
}

struct TTSPresenceWidgetProvider: TimelineProvider {
    let store: UserDefaultsTTSPresenceStore

    func placeholder(in context: Context) -> TTSPresenceWidgetEntry {
        TTSPresenceWidgetEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TTSPresenceWidgetEntry) -> Void) {
        completion(TTSPresenceWidgetEntry(date: .now, snapshot: store.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TTSPresenceWidgetEntry>) -> Void) {
        let entry = TTSPresenceWidgetEntry(date: .now, snapshot: store.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
    }
}

private struct TTSPresenceWidgetView: View {
    let entry: TTSPresenceWidgetEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot: snapshot)
                    .widgetURL(readerURL(for: snapshot))
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func content(snapshot: TTSPresenceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(snapshot.bookTitle)
                .font(.system(.headline, design: .rounded))
                .lineLimit(2)

            Text(snapshot.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusPill(text: snapshot.statusLabel)
                if let passageLabel = snapshot.passageLabel {
                    statusPill(text: passageLabel)
                }
            }

            Spacer(minLength: 0)

            Text(snapshot.isActive ? "Tap to open reader" : "Tap to continue")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Nothing is playing")
                .font(.system(.headline, design: .rounded))

            Text("Open a book to start narration.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func statusPill(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
    }

    private func readerURL(for snapshot: TTSPresenceSnapshot) -> URL {
        URL(string: "rishi://book/\(snapshot.bookID)")!
    }
}

@available(iOS 16.1, *)
struct TTSPresenceLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TTSPresenceAttributes.self) { context in
            LiveActivityView(snapshot: context.state.snapshot)
                .widgetURL(URL(string: "rishi://book/\(context.state.snapshot.bookID)")!)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.snapshot.statusLabel)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.snapshot.passageLabel ?? " ")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.snapshot.bookTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "speaker.wave.2.fill")
            } compactTrailing: {
                Text(context.state.snapshot.statusLabel.prefix(1))
            } minimal: {
                Image(systemName: "speaker.wave.2.fill")
            }
            .widgetURL(URL(string: "rishi://book/\(context.state.snapshot.bookID)")!)
        }
    }
}

private struct LiveActivityView: View {
    let snapshot: TTSPresenceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(snapshot.bookTitle)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(snapshot.statusLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())

                if let passageLabel = snapshot.passageLabel {
                    Text(passageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(snapshot.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.05))
        .activitySystemActionForegroundColor(.accentColor)
    }
}
