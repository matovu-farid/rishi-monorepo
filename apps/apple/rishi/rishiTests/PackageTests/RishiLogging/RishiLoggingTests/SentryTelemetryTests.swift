@testable import rishi
import Foundation
import Testing

@Suite("Sentry telemetry privacy")
struct SentryTelemetryTests {

    @Test func diagnosticPayloadKeepsOnlyAllowlistedFields() {
        let payload = TelemetryDiagnostic(
            feature: "tts",
            operation: "tts.stream.failed",
            stage: "provider",
            errorCode: "http_502",
            fields: [
                "provider": "openai",
                "http_status": "502",
                "correlation_id": "4E6A1D0F-2C73-4C3B-9B18-0D4F8C2A7E11",
                "first_chunk_ms": "184",
                "book_title": "Private book",
                "error": "provider response contained secret text",
                "request_id": "private-uuid",
            ]
        )

        #expect(payload.sanitizedFields == [
            "feature": "tts",
            "operation": "tts.stream.failed",
            "stage": "provider",
            "error_code": "http_502",
            "provider": "openai",
            "http_status": "502",
            "correlation_id": "4E6A1D0F-2C73-4C3B-9B18-0D4F8C2A7E11",
            "first_chunk_ms": "184",
        ])
    }

    @Test func correlationAndTimingFieldsAreBoundedTelemetry() {
        let payload = TelemetryDiagnostic(
            feature: "tts",
            operation: "tts.stream.complete",
            stage: "stream",
            errorCode: "completed",
            fields: [
                "correlation_id": "4E6A1D0F-2C73-4C3B-9B18-0D4F8C2A7E11",
                "duration_ms": "932",
                "chunk_count": "4",
                "byte_count": "16384",
                "text": "private narration",
            ]
        )

        #expect(payload.sanitizedFields["correlation_id"] == "4E6A1D0F-2C73-4C3B-9B18-0D4F8C2A7E11")
        #expect(payload.sanitizedFields["duration_ms"] == "932")
        #expect(payload.sanitizedFields["chunk_count"] == "4")
        #expect(payload.sanitizedFields["byte_count"] == "16384")
        #expect(payload.sanitizedFields["text"] == nil)
    }

    @Test func bridgeFilterPreservesSafeTagsAndDropsAutomaticData() {
        let filtered = SentryBridge.sanitizedEventFields(
            tags: [
                "feature": "tts",
                "operation": "tts.stream.failed",
                "book_title": "Private book",
            ],
            context: [
                "telemetry": [
                    "stage": "provider",
                    "error": "raw provider error",
                    "request_id": "private-uuid",
                ],
                "device": ["model": "private-device-detail"],
            ]
        )

        #expect(filtered.tags == [
            "feature": "tts",
            "operation": "tts.stream.failed",
        ])
        #expect(filtered.context == [
            "telemetry": ["stage": "provider"],
        ])
    }

    @Test func rawErrorDescriptionNeverBecomesSentryPayload() {
        let error = NSError(
            domain: "provider",
            code: 502,
            userInfo: [NSLocalizedDescriptionKey: "private provider response body"]
        )

        let sanitized = SentryBridge.sanitizedError(for: error, payload: TelemetryDiagnostic(
            feature: "tts",
            operation: "tts.stream.failed",
            stage: "provider",
            errorCode: "http_502"
        ))

        #expect(sanitized.domain == "org.fidexa.rishi")
        #expect(sanitized.localizedDescription == "rishi.error")
        #expect(!sanitized.localizedDescription.contains("private provider"))
    }
}
