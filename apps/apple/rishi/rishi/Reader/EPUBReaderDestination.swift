














import SwiftUI
import RishiAudio
import RishiBilling
import RishiCore
import RishiLibrary
import RishiReader
import RishiSearch
import RishiSync
import RishiUIKit
import RishiSettings

struct EPUBReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: EPUBReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: EPUBReaderPositionSyncBinding? = nil
    
    
    
    @State private var voiceEntry: ReaderVoiceEntry

    init(
        vm: EPUBReaderViewModel,
        services: BootstrappedServices,
        userId: UserID,
        onRequestPaywall: @escaping (String) -> Void
    ) {
        self._vm = State(initialValue: vm)
        self.services = services
        self.userId = userId
        self.onRequestPaywall = onRequestPaywall
        self._voiceEntry = State(initialValue: ReaderVoiceEntry(
            voicePresenter: services.voicePresenter,
            voiceLanguageProvider: { services.readerDefaults.voiceLanguage },
            onRequestPaywall: onRequestPaywall
        ))
    }

    

    var body: some View {
        EPUBReaderScreen(
            viewModel: vm,
            readerSettingsStore: services.readerSettingsStore,
            highlightStore: services.highlightStore,
            bookmarkStore: services.bookmarkStore,
            
            
            bookmarkMarkDirty: { [services] id in await services.syncEngine.markBookmarkDirty(id) },
            onReadAloud: {
                
                Task {
  
                    if readAloud == nil {
                        readAloud = ReadAloudController(
                            ttsEngine: services.ttsEngine,
                            ttsState: services.ttsState,
                            ttsSettingsStore: services.ttsSettingsStore,
                            ttsPrewarmer: services.ttsPrewarmer,
                            ttsPresence: services.ttsPresenceController,
                            coordidator: services.audioCoordinator,
                            userId: userId
                        )
                    }
                    await readAloud?.startEPUB(vm: vm)
                }
            } ,
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph
        )
        
        
        .ttsErrorAlert(state: services.ttsState)
        .task {
            
            
            
            vm.onUserNavigation = { _ in
                
                Task { await readAloud?.stop() }
            }
            syncBinding = EPUBReaderPositionSyncBinding(
                viewModel: vm,
                syncEngine: services.syncEngine
            )
            
            
            
            
            if await services.bookSearch.status(bookId: vm.book.id).shouldBackfillIndex {
                let url =  services.bookFileStorage.absoluteFileURL(for: vm.book)
                await services.indexingHook.scheduleIndexing(for: vm.book, fileURL: url)
            }
        }
        .onDisappear {
            syncBinding = nil
            
            Task { await readAloud?.stop() }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: RishiSpacing.s) {
                if let ra = readAloud {
                    ReadAloudControlsOverlay(
                        controller: ra,
                        ttsState: services.ttsState
                    )
                }
                IndexingIndicatorChip(
                    bookId: vm.book.id,
                    bookSearch: services.bookSearch
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .sheet(isPresented: Binding(
            get: { readAloud?.showPicker ?? false },
            set: { if !$0 { readAloud?.showPicker = false } }
        )) {
            if let ra = readAloud {
                VoiceAndSpeedPicker(
                    initial: ra.pickerInitial,
                    userId: userId,
                    store: services.ttsSettingsStore,
                    onDismiss: { settings in
                        ra.pickerInitial = settings
                        Task {
                            await services.ttsPresenceController.updatePlaybackSettings(
                                voice: settings.voice,
                                model: settings.model,
                                speed: settings.speed
                            )
                        }
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }
}
