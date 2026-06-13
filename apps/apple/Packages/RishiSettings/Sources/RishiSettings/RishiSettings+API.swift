// RishiSettings — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiSettings exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiSettings hosts the Settings screen and its sections. It
// composes UI from other packages (RishiBilling for billing rows,
// RishiSync for sync rows) and owns only the local telemetry store
// and the legal-links section.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 9 unused exports).

// MARK: - Views
//
// SettingsScreen              — `UI/SettingsScreen.swift`. The Settings tab root screen.
// AudioSection                — `UI/Audio/AudioSection.swift`. Voice + speed picker for TTS.
// BillingSection              — `UI/Billing/BillingSection.swift`. Plan status + Manage
//                                Subscription + Restore Purchases.
// LegalLinksSection           — `UI/LegalLinksSection.swift`. Privacy, Terms, EULA, Support links.
// SafariSheet                 — `UI/LegalLinksSection.swift`. UIViewControllerRepresentable
//                                wrapping SFSafariViewController for in-app legal links.

// MARK: - Models / Types
//
// IdentifiedURL               — `UI/LegalLinksSection.swift`. URL + Identifiable wrapper used
//                                with `.sheet(item:)` in LegalLinksSection.

// MARK: - Telemetry
//
// TelemetryStore              — `Telemetry/TelemetryStore.swift`. Protocol. Records local
//                                opt-in telemetry events.
// TelemetrySink               — `Telemetry/TelemetryStore.swift`. Protocol. Where the
//                                store forwards events (e.g. a future OSLog sink).
// UserDefaultsTelemetryStore  — `Telemetry/TelemetryStore.swift`. The production store
//                                backed by UserDefaults.

// MARK: - Kept public on purpose
//
// (Types that LOOK like they could be internal but were deliberately
// kept public during the 2026-06-13 surface audit. See commit be3736fe3.)
//
// NoOpTelemetrySink           — `Telemetry/TelemetryStore.swift`. Kept public so the app
//                                target can pass it as a default value when constructing a
//                                UserDefaultsTelemetryStore in production (no telemetry sink
//                                wired today).
