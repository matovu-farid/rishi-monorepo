#if canImport(CoreML)
import Foundation
// CoreML's MLModel / MLFeatureProvider / MLMultiArray are documented as
// thread-safe but are NOT yet Sendable-annotated in the SDK as of Xcode 16.
// `@preconcurrency` downgrades the cross-isolation diagnostics to warnings
// — we still box the MLModel reference behind an `@unchecked Sendable`
// `ModelBox` + `OSAllocatedUnfairLock` to keep the surface honest.
@preconcurrency import CoreML
import os
import RishiLogging

/// Production `BookEmbedder` that runs the vendored
/// `sentence-transformers/all-MiniLM-L6-v2` Core ML model from
/// `Bundle.module`. The model's output (`var_570`) is a 384-dim
/// L2-normalized vector — mean-pooling and normalization are baked into
/// the model graph (see the upstream `convert_minilm_to_coreml.py`'s
/// `PoolingWrapper`), so this embedder does NOT need to pool over the
/// token axis itself. It just hands the model `(input_ids, attention_mask)`
/// of shape `[1, 64]` int32 and returns the output vector as `[Float32]`.
///
/// Concurrency:
///   - `@unchecked Sendable` because the lazy `MLModel` reference is
///     guarded by an `OSAllocatedUnfairLock<MLModel?>`. The actual MLModel
///     instance is documented as thread-safe (Core ML 5+).
///   - Inference is performed via `Task.detached(priority: .userInitiated)`
///     so it does not block the actor of the calling site (typically the
///     VoiceSession actor in Plan 25-10).
///
/// Cold-load:
///   - `MLModel(contentsOf:configuration:)` compiles the `.mlmodel` to a
///     `.mlmodelc` on first use (~500 ms on dev host; sub-100 ms on A16+).
///   - `prewarm()` triggers the load once; subsequent calls are O(1).
public final class CoreMLMiniLMEmbedder: BookEmbedder, @unchecked Sendable {

    public enum EmbedderError: Error, Equatable {
        case vocabMissing
        case modelMissing
        case outputMissing
        case inferenceFailed(message: String)
    }

    private let tokenizer: MiniLMTokenizer
    private let modelURL: URL
    // MLModel is documented as thread-safe but is not Sendable-annotated in
    // the Core ML SDK. We box it inside a lock and treat the box as
    // `@unchecked Sendable` so the enclosing class can be Sendable.
    private final class ModelBox: @unchecked Sendable {
        var model: MLModel?
    }
    private let box = ModelBox()
    private let lock = OSAllocatedUnfairLock()

    public init() throws {
        guard let vocabURL = MiniLMTokenizer.defaultVocabURL() else {
            throw EmbedderError.vocabMissing
        }
        // SwiftPM compiles `.mlmodel` resources to `.mlmodelc` at build time —
        // prefer the compiled bundle if present; fall back to the raw model
        // for older toolchains.
        let compiled = Bundle.module.url(forResource: "AllMiniLML6V2", withExtension: "mlmodelc")
        let raw = Bundle.module.url(forResource: "AllMiniLML6V2", withExtension: "mlmodel")
        guard let url = compiled ?? raw else {
            throw EmbedderError.modelMissing
        }
        self.modelURL = url
        self.tokenizer = try MiniLMTokenizer(vocabURL: vocabURL, maxLength: 64)
    }

    public func prewarm() async {
        do {
            _ = try await loadIfNeeded()
        } catch {
            Log.error("rag.embedder.prewarm failed", error: error)
        }
    }

    public func embed(_ text: String) async throws -> [Float32] {
        let model = try await loadIfNeeded()
        let tokens = tokenizer.encode(text)
        let idArray = tokens.inputIds
        let maskArray = tokens.attentionMask

        // Run inference off the calling actor. ALL Core ML types
        // (MLMultiArray, MLFeatureProvider, MLModel) are non-Sendable, so
        // every construction and the unwrap to `[Float32]` happen inside
        // the detached closure. Only Sendable `[Int32]` arrays + the
        // ModelBox cross the boundary.
        let modelBox = ModelBox()
        modelBox.model = model
        let vec: [Float32] = try await Task.detached(priority: .userInitiated) { () -> [Float32] in
            guard let m = modelBox.model else {
                throw EmbedderError.inferenceFailed(message: "model lost during detach")
            }
            let inputIds = try MLMultiArray(shape: [1, 64], dataType: .int32)
            let attentionMask = try MLMultiArray(shape: [1, 64], dataType: .int32)
            for i in 0..<64 {
                inputIds[i] = NSNumber(value: idArray[i])
                attentionMask[i] = NSNumber(value: maskArray[i])
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: inputIds),
                "attention_mask": MLFeatureValue(multiArray: attentionMask),
            ])
            let out: MLFeatureProvider
            do {
                out = try m.prediction(from: provider)
            } catch {
                throw EmbedderError.inferenceFailed(message: String(describing: error))
            }
            // Vendored model exposes its single output as `var_570`.
            // Recompiled variants may rename it — fall back to the first
            // output feature if the named lookup misses.
            let multi: MLMultiArray
            if let direct = out.featureValue(for: "var_570")?.multiArrayValue {
                multi = direct
            } else if let firstName = out.featureNames.first,
                      let first = out.featureValue(for: firstName)?.multiArrayValue {
                multi = first
            } else {
                throw EmbedderError.outputMissing
            }
            guard multi.count >= 384 else { throw EmbedderError.outputMissing }
            var result = [Float32](repeating: 0, count: 384)
            for i in 0..<384 {
                result[i] = Float32(truncating: multi[i])
            }
            return result
        }.value
        return vec
    }

    // MARK: - Private

    private func loadIfNeeded() async throws -> MLModel {
        let cached: MLModel? = lock.withLock { _ in box.model }
        if let cached { return cached }
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // SwiftPM does not run `coremlc compile` on `.mlmodel` resources at
        // package build time (only the Xcode build system does). When we
        // hit a raw `.mlmodel`, defer compilation to runtime via
        // `MLModel.compileModel(at:)`. The compiled `.mlmodelc` is written
        // to a temporary URL under `~/Library/Caches/...`; subsequent
        // loads use the in-process cache via `box.model`.
        let modelToLoad: URL
        if modelURL.pathExtension == "mlmodelc" {
            modelToLoad = modelURL
        } else {
            modelToLoad = try await MLModel.compileModel(at: modelURL)
        }

        let model = try MLModel(contentsOf: modelToLoad, configuration: config)
        lock.withLock { _ in box.model = model }
        Log.event(
            "rag.embedder.loaded",
            level: .info,
            data: [
                "source": modelURL.lastPathComponent,
                "compiled": modelToLoad.lastPathComponent,
            ]
        )
        return model
    }
}
#endif
