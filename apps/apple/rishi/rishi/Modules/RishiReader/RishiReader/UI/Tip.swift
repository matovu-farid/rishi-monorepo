//
//  File.swift
//  RishiReader
//
//  Created by Farid Matovu on 29/06/2026.
//

import Foundation
import SwiftUI
import TipKit

public struct OnboardingGuidancePolicy {
    public static func suppressesReaderTips(isTourActive: Bool) -> Bool {
        isTourActive
    }

    public static func suppressesImportTip(
        firstBookGuidanceActive: Bool,
        recoveryPending: Bool
    ) -> Bool {
        firstBookGuidanceActive || recoveryPending
    }
}

private struct OnboardingTipsSuppressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var onboardingTipsSuppressed: Bool {
        get { self[OnboardingTipsSuppressedKey.self] }
        set { self[OnboardingTipsSuppressedKey.self] = newValue }
    }
}

struct VoiceChatTip: Tip {
    var title: Text {
        Text("Talk with your book")
    }
    
    var message: Text? {
        Text("Ask questions, explore characters, and get explanations while you read.")
    }
    
    var image: Image? {
        Image(systemName: "waveform")
    }
}

struct ReadAloudTip: Tip {
    var title: Text {
        Text("Listen as you read")
    }
    
    var message: Text? {
        Text("Listen to your book with natural voices and easily resume where you left off.")
    }
    
    var image: Image? {
        Image(systemName: "speaker.wave.2")
    }
}
