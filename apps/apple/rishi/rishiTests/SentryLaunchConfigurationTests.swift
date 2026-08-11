@testable import rishi
import Foundation
import Testing

@Suite("Sentry launch configuration")
struct SentryLaunchConfigurationTests {
    @Test("invalid DSN values resolve to nil without changing the default enabled state")
    func invalidDSNIsDisabled() {
        let invalidDSNs: [String?] = [nil, "", "$(SENTRY_DSN)"]

        for dsn in invalidDSNs {
            let resolved = SentryLaunchConfiguration.resolve(
                values: .init(dsn: dsn, environment: nil, release: nil),
                defaults: .init(environment: "debug", release: "2.1.3 (1)", enabled: true)
            )

            #expect(resolved.dsn == nil)
            #expect(resolved.enabled == true)
        }
    }

    @Test("a valid DSN survives resolution")
    func validDSNSurvivesResolution() {
        let resolved = SentryLaunchConfiguration.resolve(
            values: .init(
                dsn: "https://example@o1.ingest.sentry.io/1",
                environment: nil,
                release: nil
            ),
            defaults: .init(environment: "debug", release: "fallback", enabled: true)
        )

        #expect(resolved.dsn == "https://example@o1.ingest.sentry.io/1")
    }

    @Test("missing metadata uses build defaults")
    func missingMetadataUsesDefaults() {
        let resolved = SentryLaunchConfiguration.resolve(
            values: .init(dsn: "dsn", environment: nil, release: nil),
            defaults: .init(environment: "production", release: "2.1.3 (1)", enabled: true)
        )

        #expect(resolved.environment == "production")
        #expect(resolved.release == "2.1.3 (1)")
    }

    @Test("explicit metadata overrides build defaults")
    func explicitMetadataOverridesDefaults() {
        let resolved = SentryLaunchConfiguration.resolve(
            values: .init(dsn: "dsn", environment: "production", release: "2.1.3 (1)"),
            defaults: .init(environment: "debug", release: "fallback", enabled: true)
        )

        #expect(resolved.environment == "production")
        #expect(resolved.release == "2.1.3 (1)")
    }

    @Test("persisted telemetry opt-out disables launch telemetry and an absent preference opts in")
    func telemetryPreferenceControlsEnabledState() {
        let optedOut = SentryLaunchConfiguration.resolve(
            values: .init(dsn: "dsn", environment: nil, release: nil),
            defaults: .init(environment: "debug", release: "fallback", enabled: false)
        )
        let absentPreference = SentryLaunchConfiguration.resolve(
            values: .init(dsn: "dsn", environment: nil, release: nil),
            defaults: .init(environment: "debug", release: "fallback", enabled: true)
        )

        #expect(optedOut.enabled == false)
        #expect(absentPreference.enabled == true)
    }

    @Test("first-run telemetry preference is persisted as opted in before startup")
    func firstRunPreferenceIsPersisted() {
        let suiteName = "SentryLaunchConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: UserDefaultsTelemetryStore.storageKey) == nil)
        #expect(SentryLaunchConfiguration.telemetryOptIn(defaults: defaults) == true)
        #expect(defaults.object(forKey: UserDefaultsTelemetryStore.storageKey) as? Bool == true)
    }

    @Test("Sentry forwarding strips structured payloads and uses fixed labels")
    func sentryPayloadsArePrivacySafe() {
        #expect(SentryBridge.sanitizedBreadcrumbData(["text": "book content"]) == nil)
        #expect(SentryBridge.breadcrumbMessage == "rishi.event")
        #expect(SentryBridge.genericErrorMessage == "rishi.error")
    }
}
