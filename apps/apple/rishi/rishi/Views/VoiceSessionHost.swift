
















import SwiftUI
import RishiCore
import RishiChat
import RishiVoice











struct VoiceSessionHost: View {

    @Bindable var presenter: VoiceSessionPresenter
    let services: BootstrappedServices
    let userId: UserID

    @State private var showTextChat = false
    @State private var textVM: ChatPanelViewModel?

    var body: some View {
        voiceContent
            .sheet(isPresented: $showTextChat) {
                textChatSheet
            }
            .onAppear {
                
                
                if presenter.pendingInitialQuote != nil {
                    showTextChat = true
                }
            }
            
            
            
            
            
            
            
            .onChange(of: presenter.state.status, initial: true) { _, status in
                if case .failed(let reason) = status {
                    presenter.enterFailure(reason: reason)
                }
            }
    }

    
    
    
    
    
    
    
    @ViewBuilder
    private var voiceContent: some View {
        let state = presenter.state
        switch state.status {
        case .failed, .ended:
            
            
            Color.clear
        default:
            VoiceSessionView(
                state: state,
                
                onEnd: { Task { await presenter.end() } },
                onOpenTextChat: { showTextChat = true }
            )
        }
    }

    
    
    
    
    @ViewBuilder
    private var textChatSheet: some View {
        NavigationStack {
            if let textVM {
                ChatPanelView(
                    viewModel: textVM,
                    initialQuote: presenter.pendingInitialQuote
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: presenter.currentBookId) {
            textVM = nil
            if let convo = try? await services.conversationLookup.findOrCreate(
                userId: userId,
                bookId: presenter.currentBookId
            ) {
                textVM = ChatPanelViewModel.make(conversation: convo, services: services)
            }
        }
    }
}
