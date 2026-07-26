@testable import rishi
import Testing


@Suite @MainActor struct EntitlementServerBridgeTests {
    @Test("pumps stream values into the reconciler server signal")
    func feedsServerSignal() async {
        let reconciler = EntitlementReconciler()
        #expect(reconciler.level == .free)
        var cont: AsyncStream<EntitlementLevel>.Continuation!
        let stream = AsyncStream<EntitlementLevel> { cont = $0 }
        cont.yield(.pro); cont.finish()
        await EntitlementServerBridge.run(levels: stream, into: reconciler)
        #expect(reconciler.level == .pro)
    }
    @Test("last value wins")
    func lastValueWins() async {
        let reconciler = EntitlementReconciler()
        var cont: AsyncStream<EntitlementLevel>.Continuation!
        let stream = AsyncStream<EntitlementLevel> { cont = $0 }
        cont.yield(.pro); cont.yield(.free); cont.finish()
        await EntitlementServerBridge.run(levels: stream, into: reconciler)
        #expect(reconciler.level == .free)
    }
}
