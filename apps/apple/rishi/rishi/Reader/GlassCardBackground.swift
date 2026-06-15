//
//  GlassCardBackground.swift
//  rishi
//

import SwiftUI

/// Floating-card surface for the read-aloud controls. iOS 26 gets a native
/// Liquid Glass effect; iOS 18 falls back to `.regularMaterial`. Both clip to
/// the same rounded rectangle so the card shape is identical across versions.
struct GlassCardBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .clipShape(shape)
        }
    }
}
