import CoreGraphics
import SwiftUI

/// Placeholder surface for the voice character composition.
///
/// Exposes the native 138×179 artwork aspect ratio used by
/// ``VoiceSessionView/characterSlotSize``. Rich layered animation belongs in a
/// fuller character implementation; this type only anchors the layout contract.
public struct VoiceCharacterView: View {

    /// Width ÷ height of the supplied 138×179 character composition.
    nonisolated public static let canvasAspectRatio: CGFloat = 138.0 / 179.0

    public var body: some View {
        Color.clear
            .aspectRatio(Self.canvasAspectRatio, contentMode: .fit)
    }
}
