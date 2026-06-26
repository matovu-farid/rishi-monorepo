

import SwiftUI
#if targetEnvironment(macCatalyst)
import RishiReader   
import RishiSync     
import RishiAudio    
#endif

struct RishiMenuCommands: Commands {

    let router: MacCommandRouter
    let account: MacAccountMenuModel

    init(router: MacCommandRouter, account: MacAccountMenuModel) {
        self.router = router
        self.account = account
    }

    var body: some Commands {
        
        
        
        
        
        
        #if targetEnvironment(macCatalyst)
        CommandGroup(after: .appInfo) {
            Menu("Account") {
                AccountMenuItems(account: account)
            }
        }
        #endif

        
        
        CommandGroup(replacing: .newItem) {
            Button("Import Book…") { router.send(.importBook) }
                .keyboardShortcut(RishiKeyboardShortcut.importBook.key,
                                  modifiers: RishiKeyboardShortcut.importBook.modifiers)
            Button("New Conversation") { router.send(.newConversation) }
                .keyboardShortcut("n", modifiers: .command)
        }

        
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { router.send(.focusSearch) }
                .keyboardShortcut(RishiKeyboardShortcut.find.key,
                                  modifiers: RishiKeyboardShortcut.find.modifiers)
        }

        
        
        
        
        
        
        
        CommandGroup(after: .sidebar) {
            #if targetEnvironment(macCatalyst)
            
            
            
            
            
            
            
            ThemeMenuItems()
            PDFViewModeMenuItems()
            AudioMenuItems()
            Divider()
            #endif
            
            
            Button("Increase Font Size") { router.send(.fontIncrease) }
                .keyboardShortcut(RishiKeyboardShortcut.fontIncrease.key,
                                  modifiers: RishiKeyboardShortcut.fontIncrease.modifiers)
            Button("Decrease Font Size") { router.send(.fontDecrease) }
                .keyboardShortcut(RishiKeyboardShortcut.fontDecrease.key,
                                  modifiers: RishiKeyboardShortcut.fontDecrease.modifiers)
            Divider()
            
            
            
            
            
            
            
            Button("Find in Book") { router.send(.focusSearch) }
            Button("Add Bookmark") { router.send(.addBookmark) }
                .keyboardShortcut(RishiKeyboardShortcut.addBookmark.key,
                                  modifiers: RishiKeyboardShortcut.addBookmark.modifiers)
            Divider()
            #if targetEnvironment(macCatalyst)
            SyncMenuItems()
            Divider()
            #endif
            Button("Library") { router.send(.selectTab(.library)) }
                .keyboardShortcut(RishiKeyboardShortcut.libraryTab.key,
                                  modifiers: RishiKeyboardShortcut.libraryTab.modifiers)
            Button("Chats")   { router.send(.selectTab(.chats)) }
                .keyboardShortcut(RishiKeyboardShortcut.chatsTab.key,
                                  modifiers: RishiKeyboardShortcut.chatsTab.modifiers)
        }

        
        
        CommandGroup(after: .windowArrangement) {
            Button("Reader") { router.send(.selectTab(.library)) }
        }
    }
}

#if targetEnvironment(macCatalyst)













private struct ThemeMenuItems: View {
    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Picker("Theme", selection: prefs?.theme ?? .constant(.light)) {
            Text("Light").tag(ReaderTheme.light)
            Text("Sepia").tag(ReaderTheme.sepia)
            Text("Dark").tag(ReaderTheme.dark)
        }
        .pickerStyle(.inline)
        .disabled(prefs == nil)
    }
}



private struct PDFViewModeMenuItems: View {
    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Picker("PDF View Mode", selection: prefs?.pdfViewMode ?? .constant(.automatic)) {
            ForEach(PDFViewModeSetting.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.inline)
        .disabled(prefs == nil)
    }
}




private struct AudioMenuItems: View {
    
    
    private static let speedSteps: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Menu("Audio") {
            Picker("Voice", selection: prefs?.voice ?? .constant(VoiceCatalog.all[0])) {
                ForEach(VoiceCatalog.all, id: \.self) { voice in
                    Text(VoiceCatalog.displayName(for: voice)).tag(voice)
                }
            }
            .pickerStyle(.inline)
            Picker("Speed", selection: prefs?.speed ?? .constant(1.0)) {
                ForEach(Self.speedSteps, id: \.self) { step in
                    Text(Self.speedLabel(step)).tag(step)
                }
            }
            .pickerStyle(.inline)
        }
        .disabled(prefs == nil)
    }

    private static func speedLabel(_ value: Double) -> String {
        String(format: "%gx", value)
    }
}





private struct SyncMenuItems: View {
    @FocusedValue(\.readerPrefsMenu) private var prefs
    var body: some View {
        Menu("Sync") {
            Toggle("Auto Sync", isOn: prefs?.autoSync ?? .constant(true))
                .disabled(prefs == nil)
            Button("Sync Now") { prefs?.onSyncNow() }
                .disabled(prefs == nil)
            Divider()
            Text(Self.statusLine(prefs?.syncStatus))
                .disabled(true)
        }
        .disabled(prefs == nil)
    }

    
    
    private static func statusLine(_ status: SyncStatus?) -> String {
        guard let status else { return "Not synced" }
        if status.isRunning { return "Syncing…" }
        if let error = status.lastError, !error.isEmpty {
            return "Sync error: \(error)"
        }
        if let last = status.lastSyncedAt {
            let formatted = last.formatted(date: .abbreviated, time: .shortened)
            if status.pendingCount > 0 {
                return "Last synced \(formatted) · \(status.pendingCount) pending"
            }
            return "Last synced \(formatted)"
        }
        if status.pendingCount > 0 {
            return "\(status.pendingCount) pending"
        }
        return "Not synced yet"
    }
}















private struct AccountMenuItems: View {
    let account: MacAccountMenuModel
    var body: some View {
        let payload = account.payload
        
        
        
        Text(payload?.userEmail ?? "Not signed in")
            .disabled(true)
        Text(Self.aboutLine)
            .disabled(true)
        Divider()
        Button("Manage Subscription…") { payload?.onManageSubscription() }
            .disabled(payload == nil)
        Button("Sign Out") { payload?.onSignOut() }
            .disabled(payload == nil)
        Divider()
        Button("Privacy Policy") { payload?.onOpenPrivacy() }
            .disabled(payload == nil)
        Button("Terms of Use") { payload?.onOpenTerms() }
            .disabled(payload == nil)
    }

    
    
    private static var aboutLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "rishi \(short) (\(build))"
    }
}

#endif
