import SwiftUI


/// Animated bar waveform for the reader voice pill. Phase-driven in v1;
/// may later incorporate output audio level.
public struct VoiceWaveformView: View {
    public let phase: VoiceActivityPhase

    private static let barCount = 5
    private static let barWidth: CGFloat = 4
    private static let maxBarHeight: CGFloat = 32
    private static let minBarHeight: CGFloat = 6

    public init(phase: VoiceActivityPhase) {
        self.phase = phase
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: RishiSpacing.xs) {
                ForEach(0 ..< Self.barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor)
                        .frame(width: Self.barWidth, height: barHeight(index: index, time: time))
                }
            }
            .frame(height: Self.maxBarHeight)
        }
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        switch phase {
        case .speaking:
            return RishiColor.accent
        case .listening, .connecting, .reconnecting:
            return RishiColor.textSecondary
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let seed = Double(index + 1)
        let normalized: Double
        switch phase {
        case .speaking:
            normalized = 0.35 + 0.65 * abs(sin(time * 6.5 + seed * 1.7))
        case .listening:
            normalized = 0.25 + 0.35 * abs(sin(time * 2.0 + seed))
        case .connecting, .reconnecting:
            let stagger = time * 3.0 - seed * 0.45
            normalized = 0.2 + 0.5 * abs(sin(stagger))
        }
        let height = Self.minBarHeight + CGFloat(normalized) * (Self.maxBarHeight - Self.minBarHeight)
        return min(max(height, Self.minBarHeight), Self.maxBarHeight)
    }
}
