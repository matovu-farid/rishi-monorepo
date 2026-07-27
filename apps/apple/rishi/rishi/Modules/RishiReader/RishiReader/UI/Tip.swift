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
