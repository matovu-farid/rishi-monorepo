//
//  File.swift
//  RishiReader
//
//  Created by Farid Matovu on 29/06/2026.
//

import Foundation
import TipKit

struct VoiceChatTip: Tip {
    var title: Text {
        Text("Talk with your book")
    }
    
    var message: Text? {
        Text("Ask questions about what you're reading, explore characters, or get explanations without losing your place.")
    }
    
    var image: Image? {
        Image(systemName: "waveform.circle.fill")
    }
}

struct ReadAloudTip: Tip {
    var title: Text {
        Text("Listen as you read")
    }
    
    var message: Text? {
        Text("Have the book read aloud with natural-sounding voices. Playback remembers your place so you can continue anytime.")
    }
    
    var image: Image? {
        Image(systemName: "speaker.wave.2.fill")
    }
}
