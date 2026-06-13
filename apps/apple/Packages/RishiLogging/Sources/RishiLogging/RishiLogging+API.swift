// RishiLogging — Public API Index
//
// This file is the package's "front door." If you want to know what
// RishiLogging exports, read this file first. Nothing here is a new
// public symbol — comments only. Update this file when you add or
// remove a public type.
//
// RishiLogging is the structured-logging facade. `Log` is the
// one-line entry point callers use; sinks plug in behind it.
// The default sink fans out to os.Logger; debug builds in the
// simulator also append to a JSON file for the kanban tooling.
//
// Last verified: 2026-06-13 (against commit HEAD after the public-
// surface audit, which removed 1 unused export).

// MARK: - Facade
//
// Log                         — `Log.swift`. Namespace enum. Static methods (`debug`,
//                                `info`, `warning`, `error`) the rest of the codebase calls.
// RishiLogging                — `RishiLogging.swift`. Namespace enum for configuration:
//                                registering sinks, setting the global log level.

// MARK: - Models / Types
//
// LogLevel                    — `LogEvent.swift`. .debug / .info / .warning / .error.

// MARK: - Sinks
//
// LogSink                     — `LogSink.swift`. Protocol. A destination for log events.
// SimulatorDumpSink           — `Sinks/SimulatorDumpSink.swift`. Appends events as JSON to
//                                a per-run file under the simulator's Documents directory,
//                                used by the agentic kanban tooling to inspect failures.
