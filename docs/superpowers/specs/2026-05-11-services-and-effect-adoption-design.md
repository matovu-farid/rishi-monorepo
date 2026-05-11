# Services and Effect-TS adoption — meta-spec

**Status:** draft 2026-05-11
**Scope:** `apps/rishi-electron` only. This is a meta-spec covering the *direction* of a multi-service refactor. Each of the 6 services in scope gets its own brainstorm → spec → plan cycle. No per-service interface design happens here.

## Background

A codebase exploration surfaced architectural friction across multiple clusters in `apps/rishi-electron`. The common pattern: one cohesive concept (voice chat, RAG, TTS, sync) is split across several shallow modules in different paradigms (Zustand stores + xstate machines + procedural singletons + IPC handlers), with no single owner of the concept. Symptoms:

- Voice chat lifecycle is co-owned by `voiceChatService`, `voiceChatMachine`, and `chatStore` — three patterns for one feature.
- RAG retrieval is duplicated inline in `useChat` and `buildRealtimeAgent`, with no shared service.
- TTS is layered as `ttsService` → `ttsQueue` → `ttsCache` → `ttsPrefetch`, each layer shallow, with cross-layer coupling.
- Sync is wrapped but not orchestrated; `triggerSyncOnWrite()` is sprinkled across call sites.
- Book import logic is scattered across format-specific IPC handlers with no pipeline abstraction.
- Connectivity is a singleton actor reached into directly from multiple modules.

The fix is to deepen each cluster into a single service with a small interface hiding a larger implementation, then — only after that lands — selectively adopt Effect-TS inside the services where it concretely earns its keep.

## Decision summary

| Question | Decision |
|---|---|
| Approach | Two-stage: services first, Effect-TS adoption second |
| Services in scope | 6 (RAG, Connectivity, TTS, Sync, Voice Chat, Book Import) |
| Out of scope | IPC consolidation — future separate spec after Stage 1 ships |
| Ordering principle | Dependency-driven (Wave 1 leaves → Wave 2 dependents) |
| Stage 2 trigger | All 6 Stage 1 services merged and stable |
| Effect at public interfaces | Default no; exception clause requires per-service justification |
| Effect across IPC boundary | Never |
| Migration approach | In-place deepening, atomic per-service PRs |
| Test placement | Boundary tests on new interface; delete shallow-module tests |
| Old shallow files | Deleted, not retained as shims |

## Stage structure & philosophy

The work splits into two stages, sequenced strictly:

**Stage 1 — Service decomposition (plain TypeScript).** Deepen 6 currently-shallow clusters into cohesive services with small, well-defined interfaces. No Effect-TS yet. The output of each refactor is: one public interface, one boundary test suite, the old shallow files deleted. Each service ships independently.

**Stage 2 — Selective Effect adoption.** Begins only after Stage 1 lands. We evaluate each service against a rubric (concurrency? retries? typed errors? resource lifecycle?) and adopt Effect *inside* the ones that score high. Public interfaces of each service do not change in Stage 2 (with a narrow exception clause defined below). Services that score low stay plain TypeScript indefinitely.

**Why this order.** Stage 1 delivers architectural value standalone. If Stage 2 is abandoned for any reason — team capacity, paradigm regret, anything — the codebase is still strictly better than today. Stage 2 becomes a series of small, reversible internal optimizations, not a paradigm bet.

**This is a meta-spec.** It commits to *direction*, not *interfaces*. Each of the 6 services gets its own brainstorm → spec → plan cycle when its turn comes. The detailed interface design happens then, not now.

## Service catalog

Each service entry below names: what it owns, what it hides, what it depends on, who calls it.

### 1. RAG service

- **Owns:** "given a query + book, return ranked context chunks."
- **Hides:** embedding call, vector search, sqlite chunk lookup, ranking.
- **Depends on:** main-process vector DB + sqlite (via IPC), embedding provider.
- **Consumers:** `useChat`, `buildRealtimeAgent`. Today both duplicate this pattern inline.

### 2. Connectivity service

- **Owns:** the single source of truth for "are we online right now?" plus an event stream for transitions.
- **Hides:** `navigator.onLine`, the underlying xstate actor, optional network probes.
- **Depends on:** browser online events.
- **Consumers:** Voice Chat (offline tear-down), Sync (backoff), UI network banner.

### 3. TTS service

- **Owns:** end-to-end TTS request lifecycle — "give me audio for this text at this priority."
- **Hides:** provider HTTP, priority queue, retries, dedup, persistent cache, prefetch policy.
- **Depends on:** TTS provider (external), cache storage.
- **Consumers:** player, paragraph readers. Replaces the current `ttsService` / `ttsQueue` / `ttsCache` / `ttsPrefetch` quartet.

### 4. Sync service

- **Owns:** "schedule a write; we'll get it to the server eventually."
- **Hides:** debounce, coalescing, backoff, retry, online-gating, transport.
- **Depends on:** sync backend transport (owned by us — a port), Connectivity service.
- **Consumers:** `useChat`, stores that persist user state. Replaces scattered `triggerSyncOnWrite()` calls.

### 5. Voice Chat service

- **Owns:** the voice chat session lifecycle — start, stop, pause, recover.
- **Hides:** xstate machine wiring, realtime SDK, media stream acquisition, idle timers, activation coordination (`_chatGeneration`, `_isStarting`).
- **Depends on:** RAG service, Connectivity service, realtime transport (port).
- **State pattern:** xstate stays — but stays *inside* the service. Callers see a procedural API + a state-snapshot subscription. The Zustand `chatStore` collapses into that subscription.
- **Consumers:** chat UI.

### 6. Book Import pipeline

- **Owns:** "import this file; make it a usable, indexed book."
- **Hides:** format detection, parsing, metadata extraction, storage, chunking, embedding (via RAG service).
- **Depends on:** per-format adapters (pluggable), RAG service (for indexing), filesystem.
- **Consumers:** import UI.

### Cross-cutting note on dependencies

In Stage 1, dependencies are passed as constructor args / factory params — no DI framework, no `Layer`. Singletons live at one well-known wiring site per process. In Stage 2, services that adopt Effect convert to `Layer` / `Context.Tag` internally; the wiring site changes but the public surface does not.

## Sequencing & dependency rationale

Two waves emerge from the dependency graph. Within a wave, items are parallel-able if multiple people work this; the sequential numbering below is the right order for a solo path.

### Wave 1 — leaves, no service dependencies on each other

1. **RAG** *(do first regardless)* — strict leaf, unblocks the highest-payoff downstream service (Voice Chat) and removes duplication in `useChat` the day it lands. Highest "unblocks-most" score in the graph.
2. **Connectivity** — leaf and tiny; gets it out of the way before Voice Chat needs it as a port. Realistically a half-day refactor.
3. **TTS** — leaf, no downstream dependents. Strong candidate for the *first* Stage-2 Effect retrofit (queue/retry/dedup), so it must be deepened cleanly in Stage 1.
4. **Sync** — leaf, no downstream dependents. Same rationale as TTS.

### Wave 2 — depend on Wave 1

5. **Voice Chat** — blocked by RAG (context retrieval port) and Connectivity (offline detection port). Highest-friction feature today; this is where the architectural payoff feels biggest.
6. **Book Import** — blocked by RAG (indexing port). Lowest urgency since format-add work is rare, but it is the natural cap to Stage 1.

### Parallelization notes

- TTS, Sync, and Connectivity can run in parallel with RAG if a second pair of hands is available.
- Voice Chat and Book Import can run in parallel once Wave 1 is complete (they share only RAG as a dependency, which is read-only from their perspective).

### Explicitly deferred

IPC consolidation. It gets its own spec after Stage 1 ships, when we know what the domain services actually look like.

### Stage discipline

Even if a Stage 2 Effect adoption looks compelling for a service mid-Stage-1, we finish Stage 1 first. Stage 1 is a strict gate. Resisting that temptation is part of the discipline; the whole point of staging was to keep them separable.

## Effect-TS adoption rule

This section governs Stage 2 only. Stage 1 explicitly does not use Effect.

### When Stage 2 starts

All 6 Stage 1 services are merged, callers migrated, old shallow files deleted, boundary tests passing. No partial-adoption state where some services are still mid-refactor.

### Per-service adoption rubric

Effect goes into a service only if it scores positively on **at least two** of these axes:

| Axis | What Effect provides |
|---|---|
| Concurrency | `Queue`, `Semaphore`, `Effect.race`, dedup primitives |
| Retry / scheduling | `Schedule` for backoff, debounce, repeat |
| Resource lifecycle | `acquireRelease` for streams, sockets, files |
| Typed error channels | `Effect.catchTags`, exhaustive error handling |
| Composed async pipeline | `Effect.gen` for sequenced async with branching |

If a service hits zero or one axis, it stays plain TypeScript. The bar is real value, not paradigm consistency.

### Predicted scores

These are informed guesses; the actual decision happens once the Stage 1 code exists.

- **TTS** → yes (concurrency, retry, lifecycle, dedup — hits 4 axes)
- **Sync** → yes (concurrency, retry, scheduling — hits 3 axes)
- **Book Import** → yes (pipeline, error channels, resource lifecycle — hits 3 axes)
- **RAG** → likely no (mostly DB reads + ranking; maybe typed errors. Decide at the time.)
- **Voice Chat** → hybrid: xstate stays for the FSM (Effect doesn't replace state machines); Effect-shaped *ports* for I/O (realtime transport, mic acquisition, RAG access). The public boundary defaults to plain TS, but Voice Chat is the most likely service to invoke the exception clause — its need to cancel a tree of in-flight async work (RAG query + realtime audio + queued TTS + prefetch) on user-initiated stop is the strongest "structured cancellation" case in the codebase. Decide in the Voice Chat Stage 2 spec.
- **Connectivity** → no. Trivial.

### Public-interface rule (with exception clause)

**Default:** services keep plain TypeScript public interfaces (`Promise<T>`, `EventEmitter` / callback subscriptions, async iterators).

**Exception clause:** a service may propose Effect at its public interface in its own Stage 2 spec, but only with a concrete justification — *structured cancellation* across nested async, *exhaustive typed error handling* by callers, or *composable streaming with backpressure*. The justification names the callers and the failure modes that plain TS handles poorly.

**Caller cost.** Once a service crosses the boundary, every direct caller must either use Effect or wrap with `Effect.runPromise` at its edge. The Stage 2 spec for that service must list every caller and confirm the migration is acceptable.

**IPC boundary stays plain.** Effect never crosses the renderer/main process boundary — that boundary remains a serialization barrier. Effect lives within a process.

### Stopping rule

If the *first* Stage 2 adoption (probably TTS) goes badly — ergonomics painful, team unproductive, debugging worse — Stage 2 stops and Effect is removed from that service. The remaining services stay plain TS. Stage 1's value is unaffected.

## Cross-cutting standards

These apply to every Stage 1 service refactor.

### Definition of done (per service)

A Stage 1 service refactor ships when *all* of these are true:

1. A single public-facing module exports the service's interface (one entry point, not several).
2. Every existing caller has been migrated to the new interface.
3. The old shallow files are **deleted**, not kept as compatibility shims. Single implementation, no parallel state.
4. A boundary test suite exists, exercising the service through its public interface. No tests that poke internals.
5. The existing `tsc` / `eslint` / `vitest` runs clean.

### Test strategy

- Tests go at the *new* boundary. Old tests on shallow modules (e.g., `chatStore.test.ts` mirroring xstate state) get deleted when their shallow module is absorbed — they describe implementation, not behavior.
- Dependencies are categorized per service in its own spec: in-process (merged directly), local-substitutable (use temp sqlite / in-memory vector store), or external (mock at the boundary).
- Each service spec must list at least 3 boundary-test scenarios it commits to.

### Migration strategy

- **In-place deepening, not greenfield-and-parallel.** We refactor the existing files into the new shape, in one PR per service. No "new implementation lives alongside old until callers migrate." That pattern creates two-truths bugs.
- Each PR is structured as: (a) introduce the new public interface, (b) migrate callers in the same PR, (c) delete the old files in the same PR. Atomic.
- If a service's PR is getting unmanageable in size, the per-service spec is allowed to split it (e.g., move callers in a follow-up PR) — but the split must be planned, not improvised.

### Branch & PR strategy

- One service = one PR (or a planned PR series, declared in the service's spec).
- Branched off `main`; merged via squash or fast-forward at the team's discretion.
- No long-lived feature branches. No feature flags for these refactors — public interfaces don't change observable behavior.

### Per-service spec format

Each service brainstorm produces a spec at `docs/superpowers/specs/YYYY-MM-DD-<service-name>-design.md` containing:

- Interface signature (types, methods, events)
- Usage example for the most common caller
- What's hidden (one paragraph)
- Dependency category + how each dep is handled
- 3+ boundary-test scenarios
- Caller migration list
- Files to delete

### Scope guard

A service spec must not introduce new product features. If a refactor surfaces an opportunity ("we should also add retry to TTS prefetch"), it gets captured as a follow-up issue, not absorbed into the refactor PR. Deepening only.

## Next steps

1. Approval of this meta-spec.
2. Brainstorm + spec for the first service (RAG).
3. Plan + execute the RAG refactor.
4. Repeat per service in the order above.
5. After Stage 1 lands: evaluate each service against the Stage 2 rubric; spec Stage 2 adoptions individually.
6. After Stage 1 lands: IPC consolidation gets its own spec.

## Stage 2 outcome (closed 2026-05-11)

Stage 2 is **closed** with **2 of 6 services on Effect-TS**: TTS (PR #14) and Voice Chat (PR #16). Sync and Book Import stay plain TypeScript.

### Canary results

| Canary | PR | LoC delta | Pain signals | Verdict |
|---|---|---|---|---|
| TTS | [#14](https://github.com/matovu-farid/rishi-monorepo/pull/14) | +42% (program.ts + errors.ts vs queue.ts + transport.ts) | 0/3 | Neutral |
| Voice Chat | [#16](https://github.com/matovu-farid/rishi-monorepo/pull/16) | +60% (activation-program.ts + errors.ts; service.ts shrank but didn't fully offset) | 0/3 | Neutral |

### Decision per the canary matrix

Both canaries verdict **Neutral**. Per the Voice Chat Stage 2 spec's canary matrix (Neutral + Neutral = stop), Stage 2 closes here. No Stage 2 work on Sync or Book Import. The remaining services stay plain TypeScript indefinitely.

### What we learned (for future Effect adoption decisions)

Concrete friction documented across both canaries:

1. **`Ref.unsafeGet` / `Ref.unsafeUpdate` / `Queue.unsafeSize` are not exported in `effect@3.21.2`.** Only `Ref.unsafeMake` is callable. To read/update Refs synchronously from outside Effect-land, wrap `Effect.runSync(Ref.get/update)` in local helpers.
2. **`Effect.catchAllCause` does NOT fire on `Fiber.interrupt` causes.** Use `Effect.onInterrupt` for cancellation cleanup, or rely on `acquireRelease`'s release callback.
3. **`Effect.scoped` runs finalizers on success too.** A `success` flag inversion pattern is required if you only want teardown on failure/interrupt.
4. **`Cache.make` uses the wall clock for TTL.** Tests that inject a fake clock can't drive cache expiry; the workaround is either a real-clock + sleep test or adopting Effect's `TestClock`.
5. **Generator syntax (`Effect.gen(function*() { yield* ... })`) is noisy** relative to async/await for short pipelines. Use `Effect.gen` only when the pipeline is genuinely multi-step async with branching.
6. **The Effect ↔ Promise boundary needs a workaround for surfacing interrupt vs error.** `Cause.isInterruptedOnly` is awkward at the boundary; we ended up with a sentinel `Error.message` string. This is a smell but contained.

### Rubric guidance going forward

Effect inside a service is **value-positive but not value-large**. Future services should clear a higher bar than the original 2-of-5 axes: prefer Effect only when the service hits ≥4 of 5 axes AND the service has a long-lived resource lifecycle (WebRTC connection, file stream, socket) that benefits unambiguously from `acquireRelease`. Concurrency + retry alone are not enough to clear the bar — plain TS handles those without much pain.
