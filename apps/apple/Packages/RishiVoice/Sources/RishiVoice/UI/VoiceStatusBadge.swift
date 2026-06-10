import SwiftUI
import RishiUIKit

/// Compact pill badge surfacing the current ``VoiceSessionStatus``.
///
/// Intended for embedding in a header (e.g. above the live transcript in
/// ``VoiceSessionView``) or in compact chrome that needs a quick visual hint
/// of session lifecycle. All visuals route through RishiUIKit tokens.
public struct VoiceStatusBadge: View {
    public let status: VoiceSessionStatus

    public init(status: VoiceSessionStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: RishiSpacing.s) {
            Circle()
                .fill(indicatorColor)
                .frame(width: RishiSpacing.s, height: RishiSpacing.s)
            Text(label)
                .font(RishiTypography.caption)
                .foregroundStyle(RishiColor.textSecondary)
        }
        .padding(.horizontal, RishiSpacing.m)
        .padding(.vertical, RishiSpacing.s)
        .background(
            Capsule().fill(RishiColor.surfaceElevated)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice session status: \(label)")
    }

    private var label: String {
        switch status {
        case .idle:                return "Idle"
        case .requestingMic:       return "Requesting mic"
        case .fetchingKey:         return "Connecting…"
        case .connecting:          return "Connecting…"
        case .live:                return "Live"
        case .reconnecting(let a): return "Reconnecting (\(a)/3)"
        case .ending:              return "Ending"
        case .ended:               return "Ended"
        case .failed:              return "Failed"
        }
    }

    private var indicatorColor: Color {
        switch status {
        case .live:
            return RishiColor.accent
        case .reconnecting, .connecting, .fetchingKey, .requestingMic:
            return RishiColor.textSecondary
        case .failed:
            return RishiColor.danger
        case .idle, .ending, .ended:
            return RishiColor.divider
        }
    }
}

#Preview("Live") {
    VoiceStatusBadge(status: .live)
        .padding()
}

#Preview("Reconnecting") {
    VoiceStatusBadge(status: .reconnecting(attempt: 2))
        .padding()
}

#Preview("Failed") {
    VoiceStatusBadge(status: .failed(reason: .networkLost))
        .padding()
}
