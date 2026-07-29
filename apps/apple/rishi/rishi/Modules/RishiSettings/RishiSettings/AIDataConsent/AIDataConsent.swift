import Foundation

/// Versioned data-use consent marker shared by Apple cloud-sync and AI-data flows.
public enum DataUseConsent {
    public static let currentVersion = "2026-07-29"
}

public enum DataUseConsentDisclosure {
    public static let title = "How Rishi uses your data"
    public static let summaryText = "Rishi can sync your library, reading progress, highlights, bookmarks, and conversations across your devices. When you use AI features, relevant book text, your prompts, and—only during voice conversations—audio or transcripts may be sent to the providers that power those features."
    public static let detailsTitle = "…more"
    public static let cloudSyncItems = [
        "account identity",
        "books",
        "reading progress",
        "highlights",
        "bookmarks",
        "conversations/messages",
    ]
    public static let aiProviderItems = [
        "OpenAI — prompts, book/page text, narration text, mic audio, and transcripts",
        "ElevenLabs — narration text when that provider is selected",
        "Deepgram — mic audio and transcripts for transcription",
    ]
    public static let purposeText = "Rishi uses cloud data to sync your library and reading activity across signed-in devices. AI data is used only to answer book questions, generate narration, transcribe voice input, and run voice conversations that you start."
    public static let retentionText = "OpenAI requests are sent with provider storage disabled where supported. Rishi may retain synced conversations/transcripts and cached narration audio to provide the features; provider retention is controlled by each provider’s policy. You can revoke future data use in Settings."
    public static let privacyPolicyURL = URL(string: "https://rishi.fidexa.org/privacy")!
}

/// The persisted consent decision for one signed-in account.
public struct ConsentRecord: Codable, Equatable, Sendable {
    public let version: String
    public let timestamp: Date

    public init(version: String, timestamp: Date) {
        self.version = version
        self.timestamp = timestamp
    }
}

public protocol DataUseConsentStore: Sendable {
    func setCurrentUser(_ userID: String?) async
    func record(for userID: String) async -> ConsentRecord?
    func grant(for userID: String) async
    func revoke(for userID: String) async
    func clearCurrentUser() async
    func isCurrent(for userID: String) async -> Bool
}
