import Foundation

enum SentryLaunchConfiguration {
    struct Values: Equatable {
        let dsn: String?
        let environment: String?
        let release: String?

        init(dsn: String?, environment: String?, release: String?) {
            self.dsn = dsn
            self.environment = environment
            self.release = release
        }
    }

    struct Defaults: Equatable {
        let environment: String
        let release: String
        let enabled: Bool

        init(environment: String, release: String, enabled: Bool) {
            self.environment = environment
            self.release = release
            self.enabled = enabled
        }
    }

    struct Resolved: Equatable {
        let dsn: String?
        let environment: String
        let release: String
        let enabled: Bool

        init(dsn: String?, environment: String, release: String, enabled: Bool) {
            self.dsn = dsn
            self.environment = environment
            self.release = release
            self.enabled = enabled
        }
    }

    static func resolve(values: Values, defaults: Defaults) -> Resolved {
        Resolved(
            dsn: normalized(values.dsn),
            environment: normalized(values.environment)
                ?? normalized(defaults.environment)
                ?? "debug",
            release: normalized(values.release)
                ?? normalized(defaults.release)
                ?? "unknown",
            enabled: defaults.enabled
        )
    }

    static func fromBundle(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        defaults: Defaults = Defaults(
            environment: "debug",
            release: "unknown",
            enabled: true
        )
    ) -> Resolved {
        let info = bundle.infoDictionary
        let values = Values(
            dsn: info?["SentryDSN"] as? String,
            environment: info?["SentryEnvironment"] as? String,
            release: info?["SentryRelease"] as? String
        )
        let enabled = telemetryOptIn(defaults: userDefaults)

        return resolve(
            values: values,
            defaults: Defaults(
                environment: defaults.environment,
                release: defaults.release,
                enabled: enabled
            )
        )
    }

    static func telemetryOptIn(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: UserDefaultsTelemetryStore.storageKey) != nil else {
            defaults.set(true, forKey: UserDefaultsTelemetryStore.storageKey)
            return true
        }

        return defaults.bool(forKey: UserDefaultsTelemetryStore.storageKey)
    }

    static func start() {
        let resolved = fromBundle()
        if !resolved.enabled {
            SentryBridge.purgeCachedEnvelopes()
        }
        guard let dsn = resolved.dsn else { return }

        RishiLogging.start(
            dsn: dsn,
            environment: resolved.environment,
            release: resolved.release,
            enabled: resolved.enabled
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}
