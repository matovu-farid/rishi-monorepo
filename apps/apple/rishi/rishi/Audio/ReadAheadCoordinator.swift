//
//  ReadAheadCoordinator.swift
//  rishi (Phase 34 plan 34-08 — SRP extraction from ReaderTTSBridge)
//
//  Owns the read-ahead prewarm lockstep that ReaderTTSBridge previously
//  implemented inline. Single responsibility: given the current play head and
//  the active paragraph batch, compute the read-ahead window
//  `(index+1)..<min(index+1+readAhead, count)` and drive
//  `TTSPrewarmer.warm`/`cancelAll`.
//
//  Phase 24 (D6) contract preserved verbatim: every `playCurrent` fires
//  `warm` for the next window BEFORE the engine start so the warmer's Tasks are
//  queued ahead of the playback await. An empty window slice still goes through
//  `warm([])` so the lockstep call site is uniform. Sequential advance re-issues
//  warm without cancelling (already-cached paragraphs no-op via the cache
//  layer's de-dup). On pause / stop / non-sequential jump / batch switch the
//  caller invokes `cancelAll()` before the next playback start.
//

import Foundation
import RishiAudio

/// Read-ahead prewarm lockstep against a `TTSPrewarmer`. Stateless beyond the
/// injected prewarmer + the `readAhead` window size; all window math is derived
/// from the arguments per call so the bridge no longer carries it.
@MainActor
final class ReadAheadCoordinator {

    private let prewarmer: TTSPrewarmer

    /// Number of paragraphs to prewarm ahead of the current play head.
    /// Phase 24 (D1): default 5; configurable knob (mirrors the bridge's old
    /// `readAhead` field).
    var readAhead: Int

    init(prewarmer: TTSPrewarmer, readAhead: Int = 5) {
        self.prewarmer = prewarmer
        self.readAhead = readAhead
    }

    /// Compute the read-ahead window after `index` within `paragraphs` and fire
    /// `prewarmer.warm` for it. The slice is mapped to `TTSStreamRequest`s with a
    /// nil passageId (prewarm requests are not link-back tracked). An empty slice
    /// still calls `warm([])` so the lockstep call site is uniform.
    func warm(
        after index: Int,
        in paragraphs: [String],
        voice: String,
        speed: Double
    ) async {
        let windowStart = index + 1
        let upper = min(windowStart + readAhead, paragraphs.count)
        if windowStart < upper {
            let window = paragraphs[windowStart..<upper].map { text in
                TTSStreamRequest(
                    text: text,
                    voice: voice,
                    speed: speed,
                    passageId: nil
                )
            }
            await prewarmer.warm(requests: window)
        } else {
            await prewarmer.warm(requests: [])
        }
    }

    /// Cancel all in-flight prewarms. Forwarded from the bridge's pause / stop /
    /// jump / batch-switch paths where the read-ahead window has gone stale.
    func cancelAll() async {
        await prewarmer.cancelAll()
    }
}
