@testable import rishi
import Foundation
import Testing

@Suite(.serialized)
struct DataUseConsentTests {
    private func freshDefaults() -> UserDefaults {
        let name = "test.data-use-consent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A user without a record is not current")
    func absentUserHasNoConsent() async {
        let store = UserDefaultsDataUseConsentStore(defaults: freshDefaults())

        await store.setCurrentUser("user-a")
        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("Grant persists the current version and timestamp for the user")
    func grantPersistsRecord() async {
        let before = Date()
        let defaults = freshDefaults()
        let store = UserDefaultsDataUseConsentStore(defaults: defaults)

        await store.setCurrentUser("user-a")
        await store.grant(for: "user-a")
        let record = await store.record(for: "user-a")

        #expect(record?.version == DataUseConsent.currentVersion)
        #expect(record?.timestamp ?? .distantPast >= before)
        #expect(defaults.object(forKey: "dataUseConsent.user-a") != nil)
        #expect(await store.isCurrent(for: "user-a"))
    }

    @Test("A user's consent is never inherited by another user")
    func usersAreIsolated() async {
        let store = UserDefaultsDataUseConsentStore(defaults: freshDefaults())

        await store.setCurrentUser("user-a")
        await store.grant(for: "user-a")

        #expect(await store.record(for: "user-b") == nil)
        #expect(await store.isCurrent(for: "user-b") == false)
    }

    @Test("Malformed records are ignored")
    func malformedRecordIsIgnored() async {
        let defaults = freshDefaults()
        defaults.set(Data("not-json".utf8), forKey: "dataUseConsent.user-a")
        let store = UserDefaultsDataUseConsentStore(defaults: defaults)

        await store.setCurrentUser("user-a")
        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("A record from another version is not current")
    func unsupportedVersionIsInvalid() async throws {
        let defaults = freshDefaults()
        let oldRecord = ConsentRecord(version: "2026-01-01", timestamp: Date())
        defaults.set(try JSONEncoder().encode(oldRecord), forKey: "dataUseConsent.user-a")
        let store = UserDefaultsDataUseConsentStore(defaults: defaults)

        await store.setCurrentUser("user-a")
        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("Revoke removes only the selected user's record")
    func revokeRemovesRecord() async {
        let store = UserDefaultsDataUseConsentStore(defaults: freshDefaults())

        await store.setCurrentUser("user-a")
        await store.grant(for: "user-a")
        await store.setCurrentUser("user-b")
        await store.grant(for: "user-b")
        await store.setCurrentUser("user-a")
        await store.revoke(for: "user-a")

        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
        await store.setCurrentUser("user-b")
        #expect(await store.isCurrent(for: "user-b"))
    }

    @Test("Direct reads after sign-out cannot reactivate the former user")
    func directReadAfterSignOutDoesNotReactivateUser() async {
        let store = UserDefaultsDataUseConsentStore(defaults: freshDefaults())

        await store.setCurrentUser("user-a")
        await store.grant(for: "user-a")
        await store.clearCurrentUser()

        #expect(await store.isCurrent(for: "user-a") == false)
        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("Account switching cannot read or mutate another user's consent")
    func accountSwitchRequiresMatchingCurrentUser() async {
        let store = UserDefaultsDataUseConsentStore(defaults: freshDefaults())

        await store.setCurrentUser("user-a")
        await store.grant(for: "user-a")
        await store.clearCurrentUser()

        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)

        await store.setCurrentUser("user-b")
        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
        await store.grant(for: "user-a")
        #expect(await store.record(for: "user-b") == nil)
        #expect(await store.isCurrent(for: "user-b") == false)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("Signed-out operations cannot create or access consent")
    func signedOutOperationsAreNoOp() async {
        let defaults = freshDefaults()
        let store = UserDefaultsDataUseConsentStore(defaults: defaults)

        await store.grant(for: "user-a")
        #expect(defaults.object(forKey: UserDefaultsDataUseConsentStore.key(for: "user-a")) == nil)
        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("Reads observe revocation without a stale in-memory grant")
    func readsObserveRevocation() async {
        let defaults = freshDefaults()
        let store = UserDefaultsDataUseConsentStore(defaults: defaults)

        await store.setCurrentUser("user-a")
        await store.grant(for: "user-a")
        #expect(await store.isCurrent(for: "user-a"))

        defaults.removeObject(forKey: UserDefaultsDataUseConsentStore.key(for: "user-a"))

        #expect(await store.record(for: "user-a") == nil)
        #expect(await store.isCurrent(for: "user-a") == false)
    }

    @Test("Anonymous user identifiers do not use a global fallback")
    func anonymousIdentifiersAreIgnored() async {
        let defaults = freshDefaults()
        let store = UserDefaultsDataUseConsentStore(defaults: defaults)

        await store.setCurrentUser("user-a")
        await store.grant(for: "")
        await store.grant(for: "   ")

        #expect(await store.record(for: "") == nil)
        #expect(await store.record(for: "   ") == nil)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("dataUseConsent.") })
    }

    @Test("Disclosure names both labeled data-use groups and the privacy policy")
    func disclosureContractIsComplete() {
        #expect(DataUseConsentDisclosure.title == "How Rishi uses your data")
        #expect(DataUseConsentDisclosure.cloudSyncItems.contains("account identity"))
        #expect(DataUseConsentDisclosure.cloudSyncItems.contains("books"))
        #expect(DataUseConsentDisclosure.cloudSyncItems.contains("reading progress"))
        #expect(DataUseConsentDisclosure.cloudSyncItems.contains("highlights"))
        #expect(DataUseConsentDisclosure.cloudSyncItems.contains("bookmarks"))
        #expect(DataUseConsentDisclosure.cloudSyncItems.contains("conversations/messages"))
        #expect(DataUseConsentDisclosure.aiProviderItems.contains("OpenAI"))
        #expect(DataUseConsentDisclosure.aiProviderItems.contains("ElevenLabs"))
        #expect(DataUseConsentDisclosure.aiProviderItems.contains("Deepgram"))
        #expect(DataUseConsentDisclosure.privacyPolicyURL.absoluteString == "https://rishi.fidexa.org/privacy")
    }

    @Test("Consent disclosure has compact summary and expandable details labels")
    func compactDisclosureContract() {
        #expect(DataUseConsentDisclosure.summaryText == "Rishi can sync your library, reading progress, highlights, bookmarks, and conversations across your devices. When you use AI features, relevant book text, your prompts, and—only during voice conversations—audio or transcripts may be sent to the providers that power those features.")
        #expect(DataUseConsentDisclosure.detailsTitle == "…more")
    }
}
