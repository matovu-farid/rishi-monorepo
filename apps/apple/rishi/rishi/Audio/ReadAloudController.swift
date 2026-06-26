

import Foundation
import Observation
import RishiAudio
import RishiCore
import RishiReader
#if canImport(PDFKit)
import PDFKit
#endif

@MainActor
@Observable
final class ReadAloudController {

    

    private let ttsEngine: any TTSPlaying
    private let ttsState: TTSPlaybackState
    private let ttsSettingsStore: any TTSSettingsStore
    private let ttsPrewarmer: TTSPrewarmer
    private let userId: UserID

    

    private(set) var bridge: ReaderTTSBridge? = nil
    var showControls = false
    var showPicker = false
    var pickerInitial: TTSSettings = .default

    

    private(set) var paragraphs: [String] = []
    private(set) var currentParagraph: String? = nil

    

    init(
        ttsEngine: any TTSPlaying,
        ttsState: TTSPlaybackState,
        ttsSettingsStore: any TTSSettingsStore,
        ttsPrewarmer: TTSPrewarmer,
        userId: UserID
    ) {
        self.ttsEngine = ttsEngine
        self.ttsState = ttsState
        self.ttsSettingsStore = ttsSettingsStore
        self.ttsPrewarmer = ttsPrewarmer
        self.userId = userId
    }

    

    func startPDF(vm: PDFReaderViewModel) async {
        #if canImport(PDFKit)
        guard let doc = vm.document else { return }
        let pageIndex = vm.pageIndex
        
        
        
        let extractedParagraphs = await Task.detached(priority: .userInitiated) {
            vm.paragraphsForReadAloud(document: doc, currentPageIndex: pageIndex)
        }.value
        await start(
            paragraphs: extractedParagraphs,
            onPassageChange: { [weak self, weak vm] index in
                vm?.currentReadAloudPassageIndex = index
                self?.updateCurrentParagraph(for: index)
            },
            onParagraphsExhausted: { [weak self, weak vm] in
                
                
                
                
                
                
                
                
                let next = await vm?.paragraphsForFollowingPage() ?? []
                self?.paragraphs = next
                return next
            },
            onParagraphsBeforeStart: { [weak self, weak vm] in
                
                
                
                
                
                
                
                
                
                let prev = await vm?.paragraphsForPrecedingPage() ?? []
                self?.paragraphs = prev
                return prev
            }
        )
        #endif
    }


    func startEPUB(vm: EPUBReaderViewModel) async {
        
        
        
        
        let initialParagraphs = await vm.paragraphsForReadAloud()
        await start(
            paragraphs: initialParagraphs,
            onPassageChange: { [weak self, weak vm] index in
                vm?.currentReadAloudPassageIndex = index
                self?.updateCurrentParagraph(for: index)
            },
            onParagraphsExhausted: { [weak self, weak vm] in
                
                
                
                
                
                let next = await vm?.paragraphsForFollowingResource() ?? []
                
                
                self?.paragraphs = next
                return next
            },
            onParagraphsBeforeStart: { [weak self, weak vm] in
                
                
                
                
                
                
                let prev = await vm?.paragraphsForPrecedingResource() ?? []
                self?.paragraphs = prev
                return prev
            }
        )
    }

    
    func stop() async {
        if let bridge {
            await bridge.stop()
        }
        bridge = nil
        showControls = false
        showPicker = false
        paragraphs = []
        currentParagraph = nil
    }


    func start(
        paragraphs: [String],
        onPassageChange: @escaping (Int?) -> Void,
        onParagraphsExhausted: @escaping () async -> [String] = { [] },
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] }
    ) async {
        guard !paragraphs.isEmpty else { return }
        
        if let existing = bridge {
            await existing.stop()
        }
        
        let tracker = TTSPassageTracker()
        let newBridge = ReaderTTSBridge(
            engine: ttsEngine,
            state: ttsState,
            tracker: tracker,
            prewarmer: ttsPrewarmer,
            settingsStore: ttsSettingsStore,
            userId: userId,
            onPassageChange: onPassageChange,
            onParagraphsExhausted: onParagraphsExhausted,
            onParagraphsBeforeStart: onParagraphsBeforeStart
        )
        bridge = newBridge
        self.paragraphs = paragraphs
        currentParagraph = nil
        pickerInitial = await ttsSettingsStore.load(userId: userId)
        showControls = true
        await newBridge.start(paragraphs: paragraphs)
    }

    


    func updateCurrentParagraph(for index: Int?) {
        guard let index, paragraphs.indices.contains(index) else {
            currentParagraph = nil
            return
        }
        currentParagraph = paragraphs[index]
    }
}
