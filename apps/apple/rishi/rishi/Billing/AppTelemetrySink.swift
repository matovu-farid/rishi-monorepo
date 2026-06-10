//
//  AppTelemetrySink.swift
//  rishi
//
//  Phase 11 Plan 11-06 — concrete TelemetrySink that forwards the user's
//  Settings opt-in toggle to the RishiLogging Sentry bridge.
//
//  RishiSettings deliberately does NOT depend on RishiLogging (let alone
//  Sentry directly) — the `TelemetrySink` protocol is the seam. This
//  app-layer struct is the only place that knows both halves.
//

import Foundation
import RishiSettings
import RishiLogging

/// Hooks `RishiSettings.TelemetryStore` toggles into the RishiLogging Sentry
/// bridge so opting out actually mutes uploads (SET-02).
///
/// `setEnabled(false)` flips the bridge's `isLive` gate and closes the SDK so
/// any in-flight envelopes are dropped. `setEnabled(true)` is honored only
/// when the SDK was previously started via `RishiLogging.start(...)`.
struct AppTelemetrySink: TelemetrySink {

    func setEnabled(_ enabled: Bool) async {
        RishiLogging.setSentryEnabled(enabled)
    }
}
