import Foundation
import Synchronization
import Testing
@testable import rishi

private final class BillingOwnershipURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private static let handlers = Mutex<[String: Handler]>([:])
    private let loading = Mutex<Task<Void, Never>?>(nil)
    static func register(host: String, handler: @escaping Handler) { handlers.withLock { $0[host] = handler } }
    static func remove(host: String) { _ = handlers.withLock { $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let task = Task { @Sendable [self] in
            do {
                guard let url = request.url, let host = url.host,
                      let handler = Self.handlers.withLock({ $0[host] }) else { throw URLError(.unsupportedURL) }
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        loading.withLock { $0 = task }
    }
    override func stopLoading() { loading.withLock { $0?.cancel(); $0 = nil } }
}

private struct BillingOwnershipTransport {
    let worker: WorkerClient
    let session: URLSession
    let host: String
    init(authority: SessionCredentialAuthority, handler: @escaping BillingOwnershipURLProtocol.Handler) {
        host = "\(UUID().uuidString.lowercased()).billing-ownership.test"
        BillingOwnershipURLProtocol.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingOwnershipURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        worker = WorkerClient(baseURL: URL(string: "https://\(host)")!, session: session,
                              credentialAuthority: authority,
                              dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                              admitCredentialRejection: { _, _ in .stale })
    }
    func close() { session.invalidateAndCancel(); BillingOwnershipURLProtocol.remove(host: host) }
}

private struct BillingOwnershipLaunch: CredentialBoundEntitlementLaunchRefresh {
    let authority: SessionCredentialAuthority
    func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool { self.authority === authority }
    func refreshOnDeviceEntitlementAtLaunch() async {}
    func refreshOnDeviceEntitlementAtLaunch(credentialContext: CredentialRequestContext) async {}
}

@MainActor
@Suite("Credential billing — original receipt owner", .serialized, .timeLimit(.minutes(1)))
struct CredentialBillingOwnershipTests {
    private func coordinator(_ worker: WorkerClient, authority: SessionCredentialAuthority,
                             defaults: UserDefaults) throws -> EntitlementRefreshCoordinator {
        try EntitlementRefreshCoordinator(
            entitlementService: EntitlementService(workerClient: worker, defaults: defaults, credentialAuthority: authority),
            launchRefresh: BillingOwnershipLaunch(authority: authority), credentialAuthority: authority)
    }

    @Test("late committed receipt response finishes A once without refreshing or alerting B", arguments: [true, false])
    func lateReceipt(_ verified: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let requests = BillingOwnershipRecorder()
        let finishes = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { request in
            requests.append(request.value(forHTTPHeaderField: "Authorization") ?? "none")
            await gate.suspend()
            return (200, Data("{\"verified\":\(verified),\"reason\":\"fixture\"}".utf8))
        }
        defer { transport.close() }
        let name = "billing-owner-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let refresh = try coordinator(transport.worker, authority: authority, defaults: defaults)
        let customer = try CustomerEntitlements(credentialAuthority: authority,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), workerClient: transport.worker,
            refreshCoordinator: refresh)
        let input = CustomerEntitlementReceipt(id: 7, productID: RishiProductID.readerMonthly, jws: "A-receipt",
                                               isXcode: false, finish: { finishes.append("finish-A") })
        let processing = Task { await customer.process(receipt: input, origin: .purchaseCompletion,
                                                        credentialContext: .normal(a.lease)) }
        await gate.waitUntilEntered()
        let b = try installStagingCredentials("B", authority: authority)
        await gate.resume()
        await processing.value
        #expect(finishes.values == ["finish-A"])
        #expect(requests.values == ["Bearer fixture-A"])
        #expect(customer.error == nil)
        #expect(try authority.snapshot() == b)
        #expect(defaults.data(forKey: "billing.entitlement.snapshot.v1.B") == nil)
    }

    enum SyncResponse: Sendable, Equatable, CaseIterable { case verified, rejected, transport }
    @Test("current HTTP success finishes; business reject warns; transport stays unfinished", arguments: SyncResponse.allCases)
    func currentReceipt(_ response: SyncResponse) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let events = BillingOwnershipRecorder()
        let snapshot = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 11))
        let transport = BillingOwnershipTransport(authority: authority) { request in
            if request.url?.path != "/api/billing/entitlement-sync" {
                events.append("refresh")
                return (200, snapshot)
            }
            events.append("sync")
            if response == .transport { throw URLError(.badURL) }
            return (200, Data("{\"verified\":\(response == .verified),\"reason\":\"fixture\"}".utf8))
        }
        defer { transport.close() }
        let name = "billing-current-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let customer = try CustomerEntitlements(credentialAuthority: authority,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), workerClient: transport.worker,
            refreshCoordinator: coordinator(transport.worker, authority: authority, defaults: defaults))
        let input = CustomerEntitlementReceipt(id: 7, productID: RishiProductID.readerMonthly, jws: "A-receipt",
                                               isXcode: false, finish: { events.append("finish") })
        await customer.process(receipt: input, origin: .purchaseCompletion, credentialContext: .normal(a.lease))
        switch response {
        case .verified:
            #expect(events.values == ["sync", "refresh", "finish"])
            #expect(customer.error == nil)
        case .rejected:
            #expect(events.values == ["sync", "finish"])
            #expect(customer.error == .entitlementSyncFailed)
        case .transport:
            #expect(events.values == ["sync"])
            #expect(customer.error == .entitlementSyncFailed)
        }
    }

    @Test("late A401 does not refresh or admit B and leaves A unfinished")
    func lateUnauthorized() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let requests = BillingOwnershipRecorder()
        let finishes = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { request in
            requests.append("\(request.url?.path ?? "")|\(request.value(forHTTPHeaderField: "Authorization") ?? "none")")
            await gate.suspend()
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer { transport.close() }
        let name = "billing-stale401-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let customer = try CustomerEntitlements(credentialAuthority: authority,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), workerClient: transport.worker,
            refreshCoordinator: coordinator(transport.worker, authority: authority, defaults: defaults))
        let input = CustomerEntitlementReceipt(id: 7, productID: RishiProductID.readerMonthly, jws: "A-receipt",
                                               isXcode: false, finish: { finishes.append("finish") })
        let processing = Task { await customer.process(receipt: input, origin: .purchaseCompletion,
                                                        credentialContext: .normal(a.lease)) }
        await gate.waitUntilEntered()
        let b = try installStagingCredentials("B", authority: authority)
        await gate.resume()
        await processing.value
        #expect(requests.values == ["/api/billing/entitlement-sync|Bearer fixture-A"])
        #expect(finishes.values.isEmpty)
        #expect(customer.error == nil)
        #expect(try authority.snapshot() == b)
    }

    @Test("restore captures original context before prompting; switched account receives no request")
    func restoreAfterAccountChange() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let requests = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { request in
            requests.append(request.value(forHTTPHeaderField: "Authorization") ?? "none")
            return (200, Data(#"{"verified":true}"#.utf8))
        }
        defer { transport.close() }
        let reconciler = EntitlementReconciler(initial: .unsubscribed)
        let restore = try RestoreService(reconciler: reconciler,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), credentialAuthority: authority,
            appStoreSync: { await gate.suspend() },
            activeEntitlements: { [.init(productID: RishiProductID.readerMonthly, jws: "A-receipt")] })
        let task = Task { try await restore.restore(credentialContext: .normal(a.lease)) }
        await gate.waitUntilEntered()
        let b = try installStagingCredentials("B", authority: authority)
        await gate.resume()
        await #expect(throws: RestoreError.self) { try await task.value }
        #expect(requests.values.isEmpty)
        #expect(reconciler.level == .unsubscribed)
        #expect(try authority.snapshot() == b)
    }

    @Test("duplicate in-flight receipt submits and finishes only once")
    func duplicateReceipt() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let events = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { _ in
            events.append("sync")
            await gate.suspend()
            return (200, Data(#"{"verified":false,"reason":"fixture"}"#.utf8))
        }
        defer { transport.close() }
        let name = "billing-duplicate-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let customer = try CustomerEntitlements(credentialAuthority: authority,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), workerClient: transport.worker,
            refreshCoordinator: coordinator(transport.worker, authority: authority, defaults: defaults))
        let input = CustomerEntitlementReceipt(id: 7, productID: RishiProductID.readerMonthly, jws: "A-receipt",
                                               isXcode: true, finish: { events.append("finish") })
        let first = Task { await customer.process(receipt: input, origin: .purchaseCompletion,
                                                   credentialContext: .normal(a.lease)) }
        await gate.waitUntilEntered()
        await customer.process(receipt: input, origin: .purchaseCompletion, credentialContext: .normal(a.lease))
        #expect(events.values == ["sync"])
        await gate.resume()
        await first.value
        #expect(events.values == ["sync", "finish"])
        #expect(customer.error == nil) // The existing Xcode-origin warning policy is preserved.
    }

    @Test("deletion scope cannot sync, restore, finish, or refresh")
    func deletionScopeRejected() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let events = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { _ in
            events.append("unexpected-request")
            return (200, Data(#"{"verified":true}"#.utf8))
        }
        defer { transport.close() }
        let name = "billing-deletion-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let client = EntitlementSyncClient(client: transport.worker)
        let refresh = try coordinator(transport.worker, authority: authority, defaults: defaults)
        let customer = try CustomerEntitlements(credentialAuthority: authority, entitlementSyncClient: client,
                                                workerClient: transport.worker, refreshCoordinator: refresh)
        let context = CredentialRequestContext.deletion(transactionID: UUID(), outgoingLease: a.lease)
        let input = CustomerEntitlementReceipt(id: 7, productID: RishiProductID.readerMonthly, jws: "A-receipt",
                                               isXcode: false, finish: { events.append("unexpected-finish") })
        await customer.process(receipt: input, origin: .purchaseCompletion, credentialContext: context)
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try await client.sync(transactionJWS: "A-receipt", credentialContext: context)
        }
        let restore = try RestoreService(reconciler: EntitlementReconciler(), entitlementSyncClient: client,
            credentialAuthority: authority, appStoreSync: { events.append("unexpected-prompt") }, activeEntitlements: { [] })
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await restore.restore(credentialContext: context) }
        guard case .some(.failure(let error)) = await refresh.refreshIfSignedIn(credentialContext: context) else {
            Issue.record("Deletion scope was accepted"); return
        }
        #expect(error is EntitlementRefreshError)
        #expect(events.values.isEmpty)
        #expect(customer.error == nil)
    }

    @Test("captured launch skips B projection after suspended A device enumeration")
    func launchAfterAccountChange() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let events = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { _ in
            events.append("unexpected-request")
            return (200, Data(#"{"verified":true}"#.utf8))
        }
        defer { transport.close() }
        let reconciler = EntitlementReconciler(initial: .unsubscribed)
        let restore = try RestoreService(reconciler: reconciler,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), credentialAuthority: authority,
            appStoreSync: { events.append("unexpected-prompt") }, activeEntitlements: {
                events.append("enumerate-A")
                await gate.suspend()
                return [.init(productID: RishiProductID.readerMonthly, jws: "A-receipt")]
            })
        let task = Task { await restore.refreshOnDeviceEntitlementAtLaunch(credentialContext: .normal(a.lease)) }
        await gate.waitUntilEntered()
        let b = try installStagingCredentials("B", authority: authority)
        await gate.resume()
        await task.value
        #expect(events.values == ["enumerate-A"])
        #expect(reconciler.level == .unsubscribed)
        #expect(try authority.snapshot() == b)
        // A stale launch is also rejected before re-entering the native source.
        await restore.refreshOnDeviceEntitlementAtLaunch(credentialContext: .normal(a.lease))
        #expect(events.values == ["enumerate-A"])
    }

    @Test("outgoing clear removes only that account's error and preserves catalog errors")
    func matchingErrorClear() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let events = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { request in
            events.append(request.value(forHTTPHeaderField: "Authorization") ?? "none")
            return (200, Data(#"{"verified":false,"reason":"fixture"}"#.utf8))
        }
        defer { transport.close() }
        let name = "billing-clear-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let customer = try CustomerEntitlements(credentialAuthority: authority,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), workerClient: transport.worker,
            refreshCoordinator: coordinator(transport.worker, authority: authority, defaults: defaults))
        let input = CustomerEntitlementReceipt(id: 7, productID: RishiProductID.readerMonthly, jws: "receipt",
                                               isXcode: false, finish: {})
        await customer.process(receipt: input, origin: .purchaseCompletion, credentialContext: .normal(a.lease))
        #expect(customer.error == .entitlementSyncFailed)
        customer.clearAccountProjection(lease: a.lease)
        #expect(customer.error == nil)
        let b = try installStagingCredentials("B", authority: authority)
        await customer.process(receipt: input, origin: .purchaseCompletion, credentialContext: .normal(b.lease))
        #expect(customer.error == .entitlementSyncFailed)
        customer.clearAccountProjection(lease: a.lease)
        #expect(customer.error == .entitlementSyncFailed)
        customer.clearAccountProjection(lease: b.lease)
        #expect(customer.error == nil)
        let store = Store(customerEntitlements: customer, productLoader: { _ in throw StoreError.productRequestFailed })
        await store.loadProducts()
        store.clearAccountProjection(lease: b.lease)
        #expect(store.error == .productRequestFailed)
        #expect(store.loadState == .failed)
        #expect(events.values == ["Bearer fixture-A", "Bearer fixture-B"])
    }

    @Test("coordinator rejects legacy, copied, and wrong-Worker service chains before effects",
          arguments: ["legacy", "copied", "wrong-worker", "valid"])
    func serviceConstructorBinding(_ mode: String) async throws {
        let storage = CredentialStagingMemoryPersistence()
        _ = try installStagingCredentials("A", authority: SessionCredentialAuthority(persistence: storage))
        let authority = SessionCredentialAuthority(persistence: storage)
        let copied = SessionCredentialAuthority(persistence: storage)
        let original = try authority.snapshot()
        let duplicate = try copied.snapshot()
        #expect(original.lease == duplicate.lease)
        #expect(original.ticket != duplicate.ticket)
        let requests = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { _ in
            requests.append("unexpected-primary"); return (200, Data())
        }
        let wrongTransport = BillingOwnershipTransport(authority: copied) { _ in
            requests.append("unexpected-copied"); return (200, Data())
        }
        defer { transport.close(); wrongTransport.close() }
        let name = "billing-service-binding-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service: EntitlementService
        switch mode {
        case "legacy": service = EntitlementService(workerClient: transport.worker, defaults: defaults)
        case "copied": service = EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: copied)
        case "wrong-worker": service = EntitlementService(workerClient: wrongTransport.worker, defaults: defaults, credentialAuthority: authority)
        default: service = EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: authority)
        }
        let construct = {
            try EntitlementRefreshCoordinator(entitlementService: service,
                launchRefresh: BillingOwnershipLaunch(authority: authority), credentialAuthority: authority)
        }
        if mode == "valid" { _ = try construct() }
        else { #expect(throws: CredentialAuthenticationFailure.accountChanged) { try construct() } }
        #expect(requests.values.isEmpty)
        #expect(try authority.snapshot() == original)
        #expect(try copied.snapshot() == duplicate)
    }

    @Test("copied authority cannot construct scoped customer or restore")
    func constructorMismatch() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        _ = try installStagingCredentials("A", authority: authority)
        let other = SessionCredentialAuthority(persistence: storage)
        _ = try other.snapshot()
        let requests = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { _ in
            requests.append("unexpected")
            return (200, Data(#"{"verified":true}"#.utf8))
        }
        defer { transport.close() }
        let name = "billing-mismatch-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let client = EntitlementSyncClient(client: transport.worker)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try CustomerEntitlements(credentialAuthority: other, entitlementSyncClient: client,
                workerClient: transport.worker, refreshCoordinator: coordinator(transport.worker, authority: authority, defaults: defaults))
        }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try RestoreService(reconciler: EntitlementReconciler(), entitlementSyncClient: client, credentialAuthority: other)
        }
        #expect(requests.values.isEmpty)
    }
}

private final class BillingOwnershipRecorder: Sendable {
    private let recorded = Mutex<[String]>([])
    var values: [String] { recorded.withLock { $0 } }
    func append(_ value: String) { recorded.withLock { $0.append(value) } }
}

private actor BillingLifecycleStartGate {
    private var count = 0
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    func increment() {
        count += 1
        let ready = waiting.filter { $0.0 <= count }
        waiting.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
    func wait(for minimum: Int) async {
        if count >= minimum { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { waiting.append((minimum, continuation)) }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    private func cancel() { waiting.forEach { $0.1.resume() }; waiting.removeAll() }
}

@MainActor
private final class BillingLifecycleSourceFixture {
    var transactions: [CustomerEntitlementSources.Callback] = []
    var statuses: [CustomerEntitlementSources.Callback] = []
    var initial: [CustomerEntitlementSources.Callback] = []
    let transactionStarted = BillingLifecycleStartGate()
    let statusStarted = BillingLifecycleStartGate()
    let initialStarted = BillingLifecycleStartGate()

    var sources: CustomerEntitlementSources {
        .init(transactions: { [weak self] callback in
            guard let self else { return }
            transactions.append(callback)
            await transactionStarted.increment()
            await CredentialStagingGate().suspend()
        }, statuses: { [weak self] callback in
            guard let self else { return }
            statuses.append(callback)
            await statusStarted.increment()
            await CredentialStagingGate().suspend()
        }, initial: { [weak self] callback in
            guard let self else { return }
            initial.append(callback)
            await initialStarted.increment()
            await CredentialStagingGate().suspend()
        })
    }

    func waitForStarts(_ count: Int) async {
        await transactionStarted.wait(for: count)
        await statusStarted.wait(for: count)
        await initialStarted.wait(for: count)
    }
}

@MainActor
@Suite("Billing observation — retained app lifecycle", .serialized, .timeLimit(.minutes(1)))
struct CustomerEntitlementsLifecycleTests {
    private func makeCustomer(_ authority: SessionCredentialAuthority, transport: BillingOwnershipTransport,
                              defaults: UserDefaults, sources: CustomerEntitlementSources) throws -> CustomerEntitlements {
        let service = EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: authority)
        let refresh = try EntitlementRefreshCoordinator(entitlementService: service,
            launchRefresh: BillingOwnershipLaunch(authority: authority), credentialAuthority: authority)
        return try CustomerEntitlements(credentialAuthority: authority,
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), workerClient: transport.worker,
            refreshCoordinator: refresh, sources: sources)
    }

    @Test("two scene starts share both streams and one initial replay")
    func repeatedStart() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        _ = try installStagingCredentials("A", authority: authority)
        let source = BillingLifecycleSourceFixture()
        let transport = BillingOwnershipTransport(authority: authority) { _ in throw URLError(.unsupportedURL) }
        let name = "billing-lifecycle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let customer = try makeCustomer(authority, transport: transport, defaults: defaults, sources: source.sources)
        defer { customer.stopObserving(); transport.close(); defaults.removePersistentDomain(forName: name) }
        customer.startObserving()
        customer.startObserving()
        await source.waitForStarts(1)
        #expect(source.transactions.count == 1)
        #expect(source.statuses.count == 1)
        #expect(source.initial.count == 1)
    }

    @Test("retained streams do not retain a retired customer model")
    func weakRelease() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        _ = try installStagingCredentials("A", authority: authority)
        let source = BillingLifecycleSourceFixture()
        let transport = BillingOwnershipTransport(authority: authority) { _ in throw URLError(.unsupportedURL) }
        let name = "billing-release-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { transport.close(); defaults.removePersistentDomain(forName: name) }
        var customer: CustomerEntitlements? = try makeCustomer(authority, transport: transport, defaults: defaults, sources: source.sources)
        weak var released = customer
        customer?.startObserving()
        await source.waitForStarts(1)
        customer = nil
        #expect(released == nil)
        // The fixture intentionally keeps the exact old callbacks alive.
        await source.transactions[0](.invalid)
        #expect(released == nil)
    }

    @Test("old callbacks cannot publish after explicit stop/restart")
    func retiredCallback() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        _ = try installStagingCredentials("A", authority: authority)
        let source = BillingLifecycleSourceFixture()
        let transport = BillingOwnershipTransport(authority: authority) { _ in throw URLError(.unsupportedURL) }
        let name = "billing-retired-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let customer = try makeCustomer(authority, transport: transport, defaults: defaults, sources: source.sources)
        defer { customer.stopObserving(); transport.close(); defaults.removePersistentDomain(forName: name) }
        customer.startObserving()
        await source.waitForStarts(1)
        let old = try #require(source.transactions.first)
        customer.stopObserving()
        customer.startObserving()
        await source.waitForStarts(2)
        await old(.invalid) // Ordinary uncanceled caller proves the generation fence.
        #expect(customer.error == nil)
        await source.transactions[1](.invalid)
        #expect(customer.error == .invalidTransaction)
    }

    @Test("initial replay cannot delay updates; sync/finish precede distinct best-effort verify")
    func processingOrder() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        _ = try installStagingCredentials("A", authority: authority)
        let source = BillingLifecycleSourceFixture()
        let events = BillingOwnershipRecorder()
        let transport = BillingOwnershipTransport(authority: authority) { request in
            if request.url?.path == "/api/billing/entitlement-sync" {
                events.append("sync"); return (200, Data(#"{"verified":false,"reason":"fixture"}"#.utf8))
            }
            events.append("verify")
            #expect(request.url?.path == "/auth/verify-transaction")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-A")
            throw URLError(.badURL)
        }
        let name = "billing-order-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let customer = try makeCustomer(authority, transport: transport, defaults: defaults, sources: source.sources)
        defer { customer.stopObserving(); transport.close(); defaults.removePersistentDomain(forName: name) }
        customer.startObserving()
        await source.waitForStarts(1) // Initial task is still blocked on its own gate.
        await source.transactions[0](.receipt(.init(id: 91, productID: RishiProductID.readerMonthly,
            jws: "receipt", isXcode: true, finish: { events.append("finish") })))
        #expect(events.values == ["sync", "finish", "verify"])
        #expect(customer.error == nil)
    }

    @Test("status events update the same model and refresh the original signed-in snapshot")
    func statusRefresh() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        _ = try installStagingCredentials("A", authority: authority)
        let source = BillingLifecycleSourceFixture()
        let events = BillingOwnershipRecorder()
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 4))
        let transport = BillingOwnershipTransport(authority: authority) { request in
            events.append("\(request.url?.path ?? "")|\(request.value(forHTTPHeaderField: "Authorization") ?? "none")")
            return (200, response)
        }
        let name = "billing-status-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let customer = try makeCustomer(authority, transport: transport, defaults: defaults, sources: source.sources)
        defer { customer.stopObserving(); transport.close(); defaults.removePersistentDomain(forName: name) }
        customer.startObserving()
        await source.waitForStarts(1)
        await source.statuses[0](.currentStatuses("fixture-group", []))
        #expect(customer.subscriptionStatuses["fixture-group"]?.isEmpty == true)
        #expect(events.values == ["/api/billing/me|Bearer fixture-A"])
        #expect(defaults.data(forKey: "billing.entitlement.snapshot.v1.A") != nil)
    }
}

@MainActor
@Suite("Billing restore hosts — refresh and original result", .serialized, .timeLimit(.minutes(1)))
struct BillingRestoreHostAttemptTests {
    private func coordinator(_ transport: BillingOwnershipTransport, authority: SessionCredentialAuthority,
                             defaults: UserDefaults) throws -> EntitlementRefreshCoordinator {
        try EntitlementRefreshCoordinator(
            entitlementService: EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: authority),
            launchRefresh: BillingOwnershipLaunch(authority: authority), credentialAuthority: authority)
    }

    @Test("An earlier verified grant is refreshed even when the second receipt fails", arguments: [false, true], [false, true])
    func partialGrant(_ transportFailure: Bool, _ refreshFailure: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let events = BillingOwnershipRecorder()
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 17))
        let transport = BillingOwnershipTransport(authority: authority) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-A")
            if request.url?.path == "/api/billing/entitlement-sync" {
                events.append("sync")
                if events.values.filter({ $0 == "sync" }).count == 1 {
                    return (200, Data(#"{"verified":true}"#.utf8))
                }
                if transportFailure { throw URLError(.badURL) }
                return (200, Data(#"{"verified":false,"reason":"second receipt rejected"}"#.utf8))
            }
            #expect(request.url?.path == "/api/billing/me")
            events.append("refresh")
            if refreshFailure { throw URLError(.badURL) }
            return (200, response)
        }
        defer { transport.close() }
        let name = "billing-partial-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let restore = try RestoreService(reconciler: EntitlementReconciler(),
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), credentialAuthority: authority,
            appStoreSync: { events.append("apple") },
            activeEntitlements: {
                [.init(productID: RishiProductID.readerMonthly, jws: "verified-first"),
                 .init(productID: RishiProductID.voiceMonthly, jws: "failed-second")]
            })
        do {
            _ = try await restoreAndRefresh(restoreService: restore,
                refreshCoordinator: coordinator(transport, authority: authority, defaults: defaults), credentialContext: .normal(a.lease))
            Issue.record("Partial restore must retain its original failure")
        } catch let error as RestoreError {
            if transportFailure {
                guard case .entitlementSyncFailed(let reason) = error else { Issue.record("Transport classification lost"); return }
                #expect(!reason.isEmpty)
            } else {
                #expect(error == .entitlementSyncFailed("second receipt rejected"))
            }
        }
        #expect(events.values == ["apple", "sync", "sync", "refresh"])
        #expect(try authority.snapshot() == a)
        #expect((defaults.data(forKey: "billing.entitlement.snapshot.v1.A") != nil) == !refreshFailure)
    }

    @Test("Empty and all-verified restores retain their original outcome despite refresh failure", arguments: [false, true], [false, true])
    func originalOutcome(_ hasEntitlement: Bool, _ refreshFailure: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let events = BillingOwnershipRecorder()
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 17))
        let transport = BillingOwnershipTransport(authority: authority) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-A")
            if request.url?.path == "/api/billing/entitlement-sync" {
                events.append("sync"); return (200, Data(#"{"verified":true}"#.utf8))
            }
            events.append("refresh")
            if refreshFailure { throw URLError(.badURL) }
            return (200, response)
        }
        defer { transport.close() }
        let name = "billing-outcome-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let restore = try RestoreService(reconciler: EntitlementReconciler(),
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), credentialAuthority: authority,
            appStoreSync: { events.append("apple") }, activeEntitlements: {
                hasEntitlement ? [.init(productID: RishiProductID.readerMonthly, jws: "verified")] : []
            })
        let outcome = try await restoreAndRefresh(restoreService: restore,
            refreshCoordinator: coordinator(transport, authority: authority, defaults: defaults), credentialContext: .normal(a.lease))
        #expect(outcome == (hasEntitlement ? .restored(productIds: [RishiProductID.readerMonthly]) : .nothingToRestore))
        #expect(events.values == (hasEntitlement ? ["apple", "sync", "refresh"] : ["apple", "refresh"]))
        #expect(try authority.snapshot() == a)
    }

    private enum FixtureFailure: Error { case apple }
    @Test("Apple sync failure remains the user's error after refresh", arguments: [false, true])
    func originalSyncError(_ refreshFailure: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let events = BillingOwnershipRecorder()
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 17))
        let transport = BillingOwnershipTransport(authority: authority) { _ in
            events.append("refresh")
            if refreshFailure { throw URLError(.badURL) }
            return (200, response)
        }
        defer { transport.close() }
        let name = "billing-apple-error-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let restore = try RestoreService(reconciler: EntitlementReconciler(),
            entitlementSyncClient: EntitlementSyncClient(client: transport.worker), credentialAuthority: authority,
            appStoreSync: { events.append("apple"); throw FixtureFailure.apple },
            activeEntitlements: { Issue.record("Apple failure must not enumerate receipts"); return [] })
        await #expect(throws: RestoreError.syncFailed(String(describing: FixtureFailure.apple))) {
            try await restoreAndRefresh(restoreService: restore,
                refreshCoordinator: coordinator(transport, authority: authority, defaults: defaults), credentialContext: .normal(a.lease))
        }
        #expect(events.values == ["apple", "refresh"])
        #expect(try authority.snapshot() == a)
    }
}
