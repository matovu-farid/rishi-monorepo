//
//  MacReaderPrefsMenuViewModelTests.swift
//  rishiTests
//
//  Phase 34 Plan 34-09 (SRP) — direct coverage for the view-model extracted
//  from the Catalyst `ReaderPrefsMenuPublisher` ViewModifier. The modifier
//  previously did service work inline (auth sign-out, StoreKit present, manual
//  sync, TTS-settings seed/persist) and had no unit tests; this pins the
//  decision logic the VM now owns:
//   - seed loads the live voice/speed holder and arms write-back,
//   - persist is guarded until the seed completes (no echoed save),
//   - the menu-model voice/speed bindings persist on change,
//   - the account payload routes each action to the right service and resolves
//     the email (nil when empty so the submenu falls back to "Not signed in"),
//   - manual "Sync Now" fires the sync closure.
//
//  Catalyst-gated to match the VM (the focused-value menu surface is Mac-only).
//

#if targetEnvironment(macCatalyst)

import Testing
import SwiftUI
import RishiAudio
import RishiReader
import RishiSync
@testable import rishi

@MainActor
@Suite("MacReaderPrefsMenuViewModel decision logic")
struct MacReaderPrefsMenuViewModelTests {

    /// Records the service calls the VM fans out to, so tests assert the VM
    /// routes UI intent to the right service without any real engine.
    @MainActor
    final class Spy {
        var loaded = TTSSettings(voice: "nova", speed: 1.5)
        var saved: [TTSSettings] = []
        var syncCount = 0
        var manageCount = 0
        var signOutCount = 0
        var signedOutCallback = 0
        var opened: [URL] = []
    }

    /// Build a VM wired to a spy. Reader-default bindings target local boxes so
    /// pass-through is observable; default email is a real address.
    private func makeVM(
        spy: Spy,
        email: String? = "a@b.com"
    ) -> (MacReaderPrefsMenuViewModel, theme: Box<ReaderTheme>, autoSync: Box<Bool>) {
        let theme = Box(ReaderTheme.light)
        let autoSync = Box(true)
        let pdf = Box(PDFViewModeSetting.automatic)
        let font = Box(ReaderFontFamily.system)
        let vm = MacReaderPrefsMenuViewModel(
            theme: Binding(get: { theme.value }, set: { theme.value = $0 }),
            pdfViewMode: Binding(get: { pdf.value }, set: { pdf.value = $0 }),
            fontFamily: Binding(get: { font.value }, set: { font.value = $0 }),
            autoSync: Binding(get: { autoSync.value }, set: { autoSync.value = $0 }),
            syncStatus: SyncStatus(),
            userEmail: email,
            loadSettings: { spy.loaded },
            saveSettings: { settings in spy.saved.append(settings) },
            runManualSync: { spy.syncCount += 1 },
            presentManageSubscription: { spy.manageCount += 1 },
            signOut: { spy.signOutCount += 1; spy.signedOutCallback += 1 },
            openURL: { spy.opened.append($0) }
        )
        return (vm, theme, autoSync)
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    @Test("seed loads the holder and arms write-back")
    func seedLoadsAndArms() async {
        let spy = Spy()
        let (vm, _, _) = makeVM(spy: spy)
        #expect(vm.audioPrefs.isSeeded == false)
        await vm.seed()
        #expect(vm.audioPrefs.voice == "nova")
        #expect(vm.audioPrefs.speed == 1.5)
        #expect(vm.audioPrefs.isSeeded)
    }

    @Test("persist is a no-op before the seed completes (no echoed save)")
    func persistGuardedBeforeSeed() async {
        let spy = Spy()
        let (vm, _, _) = makeVM(spy: spy)
        // Not seeded yet — the guard must skip the write entirely.
        vm.persistAudio()
        await Task.yield()
        #expect(spy.saved.isEmpty)
    }

    @Test("persist writes through once seeded")
    func persistAfterSeed() async {
        let spy = Spy()
        let (vm, _, _) = makeVM(spy: spy)
        await vm.seed()
        spy.saved.removeAll()
        vm.audioPrefs.voice = "shimmer"
        vm.persistAudio()
        // The save is spun off in a Task; drain it.
        await drain()
        #expect(spy.saved.count == 1)
        #expect(spy.saved.first?.voice == "shimmer")
    }

    @Test("voice/speed bindings update the holder and persist on change")
    func bindingsPersist() async {
        let spy = Spy()
        let (vm, _, _) = makeVM(spy: spy)
        await vm.seed()
        spy.saved.removeAll()
        let model = vm.makeModel()
        model.voice.wrappedValue = "echo"
        #expect(vm.audioPrefs.voice == "echo")
        model.speed.wrappedValue = 2.0
        #expect(vm.audioPrefs.speed == 2.0)
        await drain()
        #expect(spy.saved.count == 2)
        #expect(spy.saved.last?.speed == 2.0)
    }

    @Test("reader-default bindings pass through 1:1")
    func defaultsPassThrough() {
        let spy = Spy()
        let (vm, theme, autoSync) = makeVM(spy: spy)
        let model = vm.makeModel()
        model.theme.wrappedValue = .dark
        #expect(theme.value == .dark)
        model.autoSync.wrappedValue = false
        #expect(autoSync.value == false)
    }

    @Test("manual Sync Now fires the sync closure (ignores autoSync)")
    func syncNowFires() async {
        let spy = Spy()
        let (vm, _, autoSync) = makeVM(spy: spy)
        autoSync.value = false   // manual sync must ignore this
        let model = vm.makeModel()
        model.onSyncNow()
        await drain()
        #expect(spy.syncCount == 1)
    }

    @Test("account payload routes each action to its service")
    func accountPayloadRoutes() async {
        let spy = Spy()
        let (vm, _, _) = makeVM(spy: spy)
        let payload = vm.makeAccountPayload()
        #expect(payload.userEmail == "a@b.com")

        payload.onManageSubscription()
        payload.onSignOut()
        payload.onOpenPrivacy()
        payload.onOpenTerms()
        await drain()

        #expect(spy.manageCount == 1)
        #expect(spy.signOutCount == 1)
        #expect(spy.signedOutCallback == 1)
        #expect(spy.opened.count == 2)
    }

    @Test("empty email resolves to nil (submenu falls back to 'Not signed in')")
    func emptyEmailIsNil() {
        let spy = Spy()
        let (vm, _, _) = makeVM(spy: spy, email: "")
        #expect(vm.makeAccountPayload().userEmail == nil)
    }

    /// Drain spun-off `Task { ... }` work scheduled on the main actor.
    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

#endif
