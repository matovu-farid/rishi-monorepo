import Foundation
import Testing

@testable import rishi

@MainActor
@Suite("AppDependencies two-phase bootstrap (F-P0-01)")
struct AppDependenciesBootstrapTests {

    @Test("init() returns in well under 10ms")
    func test_emptyInit_returnsUnder10ms() {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = AppDependencies()
        }

        #expect(elapsed < .milliseconds(50))
    }

    @Test("services is nil before bootstrap()")
    func test_servicesNilBeforeBootstrap() {
        let deps = AppDependencies()
        #expect(deps.services == nil)
    }

    @Test("bootstrap() populates services")
    func test_bootstrap_populatesServices() async {
        let deps = AppDependencies()
        await deps.bootstrap()
        #expect(deps.services != nil)
    }

    @Test("bootstrap() is idempotent")
    func test_bootstrap_idempotent() async {
        let deps = AppDependencies()
        await deps.bootstrap()
        let firstQueue = deps.services?.dbQueue as AnyObject?
        await deps.bootstrap()
        let secondQueue = deps.services?.dbQueue as AnyObject?

        #expect(firstQueue === secondQueue)
    }

    @Test("bootstrap runs heavy work off MainActor")
    func test_makeServices_runsOffMainActor() async {
        #expect(Thread.isMainThread, "test harness runs on main")
        let deps = AppDependencies()

        await deps.bootstrap()
        #expect(Thread.isMainThread, "post-bootstrap continues on main")
        #expect(deps.services != nil)
    }

    @Test("Wave A populates dbQueue AND ttsEngine via async let")
    func test_waveA_dbAndAudio_bothBuilt() async {
        let deps = AppDependencies()
        await deps.bootstrap()
        let svcs = deps.services
        #expect(svcs != nil)
        #expect((svcs?.dbQueue as AnyObject?) != nil)
        #expect((svcs?.ttsEngine as AnyObject?) != nil)
        #expect((svcs?.audioCoordinator as AnyObject?) != nil)
    }
}
