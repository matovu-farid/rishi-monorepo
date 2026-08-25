import Foundation

/// Fixed-shape diagnostics that are safe to forward to Sentry.
///
/// Raw log payloads remain available to local sinks, but Sentry-facing
/// metadata must pass through this type so content and identifiers cannot leak
/// through an otherwise convenient dictionary.
public struct TelemetryDiagnostic: Equatable, Sendable {
    public let feature: String
    public let operation: String
    public let stage: String
    public let errorCode: String
    public let fields: [String: String]

    public init(
        feature: String,
        operation: String,
        stage: String,
        errorCode: String,
        fields: [String: String] = [:]
    ) {
        self.feature = feature
        self.operation = operation
        self.stage = stage
        self.errorCode = errorCode
        self.fields = fields
    }

    var sanitizedFields: [String: String] {
        var result = Self.sanitize([
            "feature": feature,
            "operation": operation,
            "stage": stage,
            "error_code": errorCode,
        ])
        result.merge(Self.sanitize(fields)) { current, _ in current }
        return result
    }

    static func sanitize(_ fields: [String: String]?) -> [String: String] {
        guard let fields else { return [:] }
        let allowed = Set([
            "feature", "operation", "stage", "error_code", "error_type",
            "provider", "http_status", "response_mode", "cache_result",
            "request_chars", "audio_generation", "correlation_id",
            "first_chunk_ms", "duration_ms", "chunk_count", "byte_count",
            "cancel_reason", "interruption_reason", "audio_route",
        ])
        return fields.reduce(into: [String: String]()) { result, pair in
            guard allowed.contains(pair.key), isSafeValue(pair.value) else { return }
            result[pair.key] = pair.value
        }
    }

    private static func isSafeValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
}
