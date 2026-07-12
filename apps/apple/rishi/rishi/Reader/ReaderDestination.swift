














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

struct ReaderDestination: View {
    let services: BootstrappedServices
    let userId: UserID
    let onRequestPaywall: (String) -> Void

    @State private var vm: ReaderViewModel
    @State private var readAloud: ReadAloudController? = nil
    @State private var syncBinding: ReaderPositionSyncBinding? = nil
    
    
    
    @State private var voiceEntry: ReaderVoiceEntry

    init(
        vm: ReaderViewModel,
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
        ReaderScreen(
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
                    await readAloud?.startReader(vm: vm)
                }
            } ,
            voicePresenter: voiceEntry,
            readAloudParagraph: readAloud?.currentParagraph,
            readAloudLocator: readAloud?.currentLocator
        )
        
        
        .ttsErrorAlert(state: services.ttsState)
        .task {
            
            
            
            vm.onUserNavigation = { _ in
                
                Task { await readAloud?.stop() }
            }
            syncBinding = ReaderPositionSyncBinding(
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
        .overlay(alignment: .bottomTrailing) {
            IndexingIndicatorChip(
                bookId: vm.book.id,
                bookSearch: services.bookSearch
            )
            .padding(.trailing, RishiSpacing.m)
            .padding(.bottom, RishiSpacing.s)
        }
        .overlay {
            if let ra = readAloud {
                ReadAloudControlsOverlay(
                    controller: ra,
                    ttsState: services.ttsState,
                    onOpenVoiceChat: {
                        Task {
                            await ra.stop()
                            voiceEntry.presentVoice(
                                bookId: vm.book.id,
                                context: vm.voiceContext(),
                                initialQuote: nil
                            )
                        }
                    }
                )
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
                        Task { await ra.applySettings(settings) }
                        ra.showPicker = false
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }
}
